#!/bin/bash

# 
# 1. Interfață Zenity pentru introducerea datelor mașinii Destinație
DEST_INFO=$(zenity --forms --title="Configurare Clonare Sistem" \
    --text="Introduceți datele mașinii virtuale Destinație:" \
    --add-entry="Utilizator Destinație (ex: clonaana):" \
    --add-entry="IP Destinație (ex: 172.20.10.5):" \
    --separator=":")

if [ $? -ne 0 ] || [ -z "$DEST_INFO" ]; then
    zenity --error --text="Operatiune anulata de utilizator."
    exit 1
fi

DEST_USER=$(echo "$DEST_INFO" | cut -d':' -f1)
DEST_IP=$(echo "$DEST_INFO" | cut -d':' -f2)

# File/Folders temporare pentru analize
OUTPUT_DIR="$HOME/raport_clonare"
mkdir -p "$OUTPUT_DIR"

(
    echo "10"; echo "# Verificare conexiune SSH cu $DEST_IP..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${DEST_USER}@${DEST_IP}" exit 2>/dev/null; then
        zenity --error --text="Nu se poate conecta prin SSH fara parola la ${DEST_USER}@${DEST_IP}.\nVerificati cheile SSH!"
        exit 1
    fi


    echo "30"; echo "# Analiza utilizatori legitimi (UID >= 1000)..."
    awk -F: '$3 >= 1000 && $3 != 65534 {print $1 ":" $3 ":" $6}' /etc/passwd > "$OUTPUT_DIR/utilizatori_legitimi.txt"

   
      echo "50"; echo "# Analiza pachetelor software instalate (apt)..."
    # Extrage pachetele de pe Sursa
    dpkg-query -f '${binary:Package}\n' -W > "$OUTPUT_DIR/pachete_sursa.txt"
    
    # Extrage pachetele de pe Destinatie prin SSH
    ssh "${DEST_USER}@${DEST_IP}" "dpkg-query -f '\${binary:Package}\n' -W" > "$OUTPUT_DIR/pachete_destinatie.txt"
    
    # Compara si salveaza doar ce lipseste pe Destinatie
    comm -23 <(sort "$OUTPUT_DIR/pachete_sursa.txt") <(sort "$OUTPUT_DIR/pachete_destinatie.txt") > "$OUTPUT_DIR/pachete_lipsa.txt"

   
      echo "70"; echo "# Identificare cronjob-uri pentru migrare..."
    > "$OUTPUT_DIR/cronjobs_export.txt"
    while IFS=: read -r user uid home; do
        CRON_DATA=$(crontab -u "$user" -l 2>/dev/null)
        if [ -n "$CRON_DATA" ]; then
            echo "=== Cronjob-uri utilizator: $user ===" >> "$OUTPUT_DIR/cronjobs_export.txt"
            echo "$CRON_DATA" >> "$OUTPUT_DIR/cronjobs_export.txt"
            echo "" >> "$OUTPUT_DIR/cronjobs_export.txt"
        fi
    done < "$OUTPUT_DIR/utilizatori_legitimi.txt"

   
     echo "90"; echo "# Sincronizare fișiere prin rsync..."
    rsync -avz --progress "$HOME/Desktop/" "${DEST_USER}@${DEST_IP}:~/Desktop/" > "$OUTPUT_DIR/rsync_log.txt" 2>&1

    echo "100"; echo "# Analiza si clonarea s-au finalizat cu succes!"

) | zenity --progress --title="Proces Clonare" --text="Initializare..." --percentage=0 --auto-close

# Afișare Raport Final cu Zenity
PACHETE_LIPSA_COUNT=$(wc -l < "$OUTPUT_DIR/pachete_lipsa.txt")
USERS_COUNT=$(wc -l < "$OUTPUT_DIR/utilizatori_legitimi.txt")

zenity --text-info --title="Rezultat Analiză și Clonare" --width=600 --height=400 \
    --filename=<(echo -e "=== RAPORT CLONARE SISTEM ===\n\n1. Utilizatori legitimi detectati: $USERS_COUNT\nSaved in: $OUTPUT_DIR/utilizatori_legitimi.txt\n\n2. Pachete APT lipsa pe Destinatie: $PACHETE_LIPSA_COUNT pachete\nSaved in: $OUTPUT_DIR/pachete_lipsa.txt\n\n3. Cronjob-uri identificate:\nSaved in: $OUTPUT_DIR/cronjobs_export.txt\n\nToate detaliile au fost salvate in directorul: $OUTPUT_DIR")
