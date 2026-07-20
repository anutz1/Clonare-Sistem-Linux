#!/bin/bash

# 1. Interfață Zenity pentru introducerea datelor mașinii Destinație
DEST_INFO=$(zenity --forms --title="Configurare Clonare Sistem TOTALĂ" \
    --text="Introduceți datele mașinii virtuale Destinație:" \
    --add-entry="Utilizator Destinație (cu drepturi sudo):" \
    --add-entry="IP Destinație:" \
    --separator=":")

if [ $? -ne 0 ] || [ -z "$DEST_INFO" ]; then
    zenity --error --text="Operațiune anulată de utilizator."
    exit 1
fi

DEST_USER=$(echo "$DEST_INFO" | cut -d':' -f1)
DEST_IP=$(echo "$DEST_INFO" | cut -d':' -f2)

OUTPUT_DIR="$HOME/raport_clonare"
mkdir -p "$OUTPUT_DIR"

(
    echo "10"; echo "# Verificare conexiune SSH cu $DEST_IP..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${DEST_USER}@${DEST_IP}" exit 2>/dev/null; then
        zenity --error --text="Nu se poate conecta prin SSH fără parolă la ${DEST_USER}@${DEST_IP}.\nVerificați cheile SSH!"
        exit 1
    fi

    echo "20"; echo "# Analiză utilizatori legitimi (UID >= 1000)..."
    awk -F: '$3 >= 1000 && $3 != 65534 {print $1 ":" $3 ":" $6}' /etc/passwd > "$OUTPUT_DIR/utilizatori_legitimi.txt"

    echo "30"; echo "# Analiză securitate parole din /etc/shadow..."
    > "$OUTPUT_DIR/status_parole.txt"
    while IFS=: read -r user uid home; do
        SHADOW_LINE=$(sudo grep "^$user:" /etc/shadow)
        PASSWORD_HASH=$(echo "$SHADOW_LINE" | cut -d':' -f2)
        echo "$user:$PASSWORD_HASH" >> "$OUTPUT_DIR/status_parole.txt"
    done < "$OUTPUT_DIR/utilizatori_legitimi.txt"

    echo "45"; echo "# Identificare pachete software (APT)..."
    dpkg-query -f '${binary:Package}\n' -W > "$OUTPUT_DIR/pachete_sursa.txt"
    ssh "${DEST_USER}@${DEST_IP}" "dpkg-query -f '\${binary:Package}\n' -W" > "$OUTPUT_DIR/pachete_destinatie.txt"
    comm -23 <(sort "$OUTPUT_DIR/pachete_sursa.txt") <(sort "$OUTPUT_DIR/pachete_destinatie.txt") > "$OUTPUT_DIR/pachete_lipsa.txt"

    # ----------------------------------------------------------------------
    # ⚡ [PARTEA A] COLECTARE REPO-URI TERȚIARE ȘI CHEI GPG (Ex: VS Code)
    # ----------------------------------------------------------------------
    echo "55"; echo "# Salvare surse software terțiare și chei GPG..."
    mkdir -p "$OUTPUT_DIR/surse_externe"
    mkdir -p "$OUTPUT_DIR/chei_securitate"
    if [ -d "/etc/apt/sources.list.d" ]; then
        cp -r /etc/apt/sources.list.d/* "$OUTPUT_DIR/surse_externe/" 2>/dev/null || true
    fi
    if [ -d "/etc/apt/trusted.gpg.d" ]; then
        cp -r /etc/apt/trusted.gpg.d/* "$OUTPUT_DIR/chei_securitate/" 2>/dev/null || true
    fi
    # ----------------------------------------------------------------------

    if command -v snap &> /dev/null; then
        snap list | awk 'NR>1 {print $1}' > "$OUTPUT_DIR/snap_sursa.txt"
    else
        touch "$OUTPUT_DIR/snap_sursa.txt"
    fi

    if command -v flatpak &> /dev/null; then
        flatpak list --columns=application > "$OUTPUT_DIR/flatpak_sursa.txt"
    else
        touch "$OUTPUT_DIR/flatpak_sursa.txt"
    fi

    echo "70"; echo "# Extragere cronjob-uri utilizatori..."
    mkdir -p "$OUTPUT_DIR/cronjobs"
    while IFS=: read -r user uid home; do
        sudo crontab -u "$user" -l > "$OUTPUT_DIR/cronjobs/${user}_cron" 2>/dev/null
    done < "$OUTPUT_DIR/utilizatori_legitimi.txt"

    echo "85"; echo "# Sincronizare directoare /home (Păstrare permisiuni intacte)..."
    # Modificat: Trimitem DIRECT în /home/ pe Destinație pentru a lăsa rsync să mențină proprietarii nativ
    sudo rsync -avz --progress /home/ "${DEST_USER}@${DEST_IP}:/home/" > "$OUTPUT_DIR/rsync_log.txt" 2>&1

    echo "100"; echo "# Analiza s-a finalizat! Se pregătește aplicarea pe Destinație..."

) | zenity --progress --title="Proces Clonare Totală" --text="Inițializare..." --percentage=0 --auto-close

# Trimitem folderul de configurări/rapoarte în /tmp pe Destinație
scp -r "$OUTPUT_DIR" "${DEST_USER}@${DEST_IP}:/tmp/"

# Pornim execuția scriptului de reconstrucție pe Destinație
zenity --info --text="Apasă OK și introdu parola în terminal pentru a porni Reconstrucția Totală pe Destinație."

ssh -t "${DEST_USER}@${DEST_IP}" "
    echo '==> [1/6] Recreare automată utilizatori și configurare parole...'
    while IFS=: read -r user uid home; do
        if ! id \"\$user\" &>/dev/null; then
            echo \"Creare utilizator \$user...\"
            sudo useradd -m -u \"\$uid\" -s /bin/bash \"\$user\"
        fi
        
        # Migrăm hash-ul parolei din shadow în mod securizat
        HASH=\$(sudo grep \"^\$user:\" /tmp/raport_clonare/status_parole.txt | cut -d':' -f2)
        if [ -n \"\$HASH\" ] && [ \"\$HASH\" != \"*\" ] && [ \"\$HASH\" != \"!\" ]; then
            sudo usermod -p \"\$HASH\" \"\$user\"
        fi
    done < /tmp/raport_clonare/utilizatori_legitimi.txt

    # ----------------------------------------------------------------------
    # ⚡ [PARTEA B] INJECTARE REPO-URI TERȚIARE ÎNAINTE DE INSTALARE APT
    # ----------------------------------------------------------------------
    echo '==> [2/6] Restaurare surse terțiare și chei GPG pe Destinație...'
    sudo cp -r /tmp/raport_clonare/surse_externe/* /etc/apt/sources.list.d/ 2>/dev/null || true
    sudo cp -r /tmp/raport_clonare/chei_securitate/* /etc/apt/trusted.gpg.d/ 2>/dev/null || true

    echo '==> Actualizare index APT cu noile surse adăugate...'
    sudo apt update -y
    # ----------------------------------------------------------------------

    echo '==> [3/6] Instalare pachete APT lipsă (inclusiv cele din surse externe)...'
    if [ -s /tmp/raport_clonare/pachete_lipsa.txt ]; then
        sudo apt install -y \$(cat /tmp/raport_clonare/pachete_lipsa.txt)
    fi

    echo '==> [4/6] Asigurare și corectare finală a permisiunilor directoarelor /home...'
    while IFS=: read -r user uid home; do
        if [ -d \"/home/\$user\" ]; then
            sudo chown -R \"\$user:\$user\" \"/home/\$user\"
        fi
    done < /tmp/raport_clonare/utilizatori_legitimi.txt

    echo '==> [5/6] Restaurare automată Cronjob-uri...'
    while IFS=: read -r user uid home; do
        if [ -f \"/tmp/raport_clonare/cronjobs/\${user}_cron\" ] && [ -s \"/tmp/raport_clonare/cronjobs/\${user}_cron\" ]; then
            sudo crontab -u \"\$user\" \"/tmp/raport_clonare/cronjobs/\${user}_cron\"
        fi
    done < /tmp/raport_clonare/utilizatori_legitimi.txt

    echo '==> [6/6] Instalare pachete moderne (Snap & Flatpak)...'
    if command -v snap &>/dev/null && [ -s /tmp/raport_clonare/snap_sursa.txt ]; then
        while read -r snap_pkg; do
            [ \"\$snap_pkg\" = \"code\" ] && sudo snap install --classic code || sudo snap install \"\$snap_pkg\"
        done < /tmp/raport_clonare/snap_sursa.txt
    fi

    if command -v flatpak &>/dev/null && [ -s /tmp/raport_clonare/flatpak_sursa.txt ]; then
        while read -r flat_pkg; do
            flatpak install -y flathub \"\$flat_pkg\"
        done < /tmp/raport_clonare/flatpak_sursa.txt
    fi

    echo '=== CLONARE TOTALĂ APLICATĂ CU SUCCES! ==='
"
