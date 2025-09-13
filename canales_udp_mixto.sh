#!/bin/bash

###############################################################################
# Script: canales_udp_mixto.sh
#
# Supervisor de canales UDP con FFmpeg personalizado por canal y audio spa.
#
# FUNCIONALIDAD PRINCIPAL:
# - Transcodifica y supervisa múltiples canales UDP para streaming RTMP.
# - Soporta NVIDIA NVENC, Intel QSV y AMD VAAPI/VPU por canal (hardware).
# - Por defecto usa NVIDIA NVENC (hardware).
# - Si en canales.txt aparece el parámetro |encoder=qsv, usa Intel QSV (hardware Intel).
# - Si aparece |encoder=vaapi, usa AMD VAAPI/VPU (hardware AMD/Intel/compatible).
# - Si aparece |encoder=cpu, se usa configuración especial con CPU: libx264, filtro yadif (desentrelazado), scale a 1280x720, bitrate 2048 kbps, audio AAC mono a 128 kbps, seleccionando audio español si está disponible.
# - Detecta automáticamente el codec de video y selecciona el decodificador HW adecuado:
#     - NVIDIA: h264_cuvid o mpeg2_cuvid
#     - QSV: h264_qsv o mpeg2_qsv
#     - VAAPI: h264_vaapi o mpeg2_vaapi
# - Permite relanzar un canal manualmente por nombre.
# - Los logs de cada canal se eliminan al iniciar el script y se restringen a 2,000 líneas o 80 KB.
###############################################################################

SCRIPT_DIR="$(cd ""$(dirname "$0")"" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# Elimina todos los logs de canales al iniciar/reiniciar el script
find "$LOG_DIR" -type f -name "*.log" -delete

CANALES_FILE="$SCRIPT_DIR/canales.txt"
RTMP_PREFIX="rtmp://fuentes.futuretv.pro:9922/tp"

# Parámetros ffmpeg por defecto (NVENC, QSV, VAAPI, CPU)
ENCODE_COMMON_NVENC="-c:v h264_nvenc -b:v 2M -bufsize 4M -preset p2 -tune 3 -g 60 -c:a aac -dts_delta_threshold 1000 -ab 128k -ar 44100 -ac 1 -f flv"
ENCODE_COMMON_QSV="-c:v h264_qsv -b:v 2M -preset medium -c:a aac -dts_delta_threshold 1000 -ab 128k -ar 44100 -ac 1 -f flv"
ENCODE_COMMON_VAAPI="-c:v h264_vaapi -b:v 2M -preset fast -c:a aac -dts_delta_threshold 1000 -ab 128k -ar 44100 -ac 1 -f flv"
MAX_FAILS=5           # Máximo número de caídas antes de pausar relanzamiento
FAIL_WINDOW=600       # Tiempo ventana para contar caídas (segundos)
declare -A FAIL_HISTORY
MAX_LOG_LINES=2000    # Máximo de líneas permitidas en cada log de canal
MAX_LOG_SIZE=81920    # Máximo tamaño del log (80KB)