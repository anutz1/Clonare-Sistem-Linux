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

    echo "35"; echo "# Analiză securitate parole din /etc/shadow..."
    > "$OUTPUT_DIR/status_parole.txt"
    while IFS=: read -r user uid home; do
        SHADOW_LINE=$(sudo grep "^$user:" /etc/shadow)
        PASSWORD_HASH=$(echo "$SHADOW_LINE" | cut -d':' -f2)
        echo "$user:$PASSWORD_HASH" >> "$OUTPUT_DIR/status_parole.txt"
    done < "$OUTPUT_DIR/utilizatori_legitimi.txt"

    echo "50"; echo "# Identificare pachete software (APT, Snap, Flatpak)..."
    dpkg-query -f '${binary:Package}\n' -W > "$OUTPUT_DIR/pachete_sursa.txt"
    ssh "${DEST_USER}@${DEST_IP}" "dpkg-query -f '\${binary:Package}\n' -W" > "$OUTPUT_DIR/pachete_destinatie.txt"
    comm -23 <(sort "$OUTPUT_DIR/pachete_sursa.txt") <(sort "$OUTPUT_DIR/pachete_destinatie.txt") > "$OUTPUT_DIR/pachete_lipsa.txt"

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

    echo "85"; echo "# Sincronizare directoare /home (Toți utilizatorii)..."
    # Folosim sudo rsync pentru a putea citi fișierele tuturor utilizatorilor (gabi, ana, etc.)
    sudo rsync -avz --progress /home/ "${DEST_USER}@${DEST_IP}:/tmp/home_sursa/" > "$OUTPUT_DIR/rsync_log.txt" 2>&1

    echo "100"; echo "# Analiza s-a finalizat! Se pregătește aplicarea pe Destinație..."

) | zenity --progress --title="Proces Clonare Totală" --text="Inițializare..." --percentage=0 --auto-close

# Trimitem folderul de configurări pe Destinație
scp -r "$OUTPUT_DIR" "${DEST_USER}@${DEST_IP}:/tmp/"

# Pornim execuția scriptului de reconstrucție pe Destinație
zenity --info --text="Apasă OK și introdu parola în terminal pentru a porni Reconstrucția Totală pe Destinație."

ssh -t "${DEST_USER}@${DEST_IP}" "
    echo '==> [1/5] Actualizare și instalare pachete APT lipsă...'
    sudo apt update && sudo apt install -y \$(cat /tmp/raport_clonare/pachete_lipsa.txt)

    echo '==> [2/5] Recreare automată utilizatori și configurare parole...'
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

    echo '==> [3/5] Mutare fișiere date în directoarele /home corespunzătoare...'
    sudo cp -r /tmp/home_sursa/* /home/
    
    # Corectăm permisiunile fișierelor pentru fiecare utilizator în parte
    while IFS=: read -r user uid home; do
        sudo chown -R \"\$user:\$user\" \"/home/\$user\"
    done < /tmp/raport_clonare/utilizatori_legitimi.txt

    echo '==> [4/5] Restaurare automată Cronjob-uri...'
    while IFS=: read -r user uid home; do
        if [ -f \"/tmp/raport_clonare/cronjobs/\${user}_cron\" ] && [ -s \"/tmp/raport_clonare/cronjobs/\${user}_cron\" ]; then
            sudo crontab -u \"\$user\" \"/tmp/raport_clonare/cronjobs/\${user}_cron\"
        fi
    done < /tmp/raport_clonare/utilizatori_legitimi.txt

    echo '==> [5/5] Instalare pachete moderne (Snap & Flatpak)...'
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
