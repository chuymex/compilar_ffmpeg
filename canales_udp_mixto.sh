#!/bin/bash

###############################################################################
# Script: canales_udp_mixto.sh
#
# Supervisor de canales UDP con FFmpeg personalizado por canal y audio spa.
# Permite transcodificación de canales UDP a RTMP, seleccionando el encoder
# por canal (NVENC/QSV/VAAPI/CPU) y el audio español si existe.
# Incluye manejo de logs, supervisión automática y relanzamiento manual.
###############################################################################

# === CONFIGURACIÓN GENERAL ===
SCRIPT_DIR="$(cd \"$(dirname \"$0\")\" && pwd)"         # Directorio del script
LOG_DIR="$SCRIPT_DIR/logs"                          # Carpeta de logs individuales por canal
mkdir -p "$LOG_DIR"

# Limpia logs al inicio para evitar archivos antiguos
find "$LOG_DIR" -type f -name "*.log" -delete

CANALES_FILE="$SCRIPT_DIR/canales.txt"              # Archivo de configuración de canales
RTMP_PREFIX="rtmp://fuentes.futuretv.pro:9922/tp"   # Prefijo para destino RTMP

# Parámetros ffmpeg comunes por encoder
ENCODE_COMMON_NVENC="-c:v h264_nvenc -b:v 2M -bufsize 4M -preset p2 -tune 3 -g 60 -c:a aac -dts_delta_threshold 1000 -ab 128k -ar 44100 -ac 1 -f flv"
ENCODE_COMMON_QSV="-c:v h264_qsv -b:v 2048k -preset medium -c:a aac -ab 128k -ar 44100 -ac 1 -dts_delta_threshold 1000 -f flv"
ENCODE_COMMON_VAAPI="-c:v h264_vaapi -b:v 2M -preset fast -c:a aac -dts_delta_threshold 1000 -ab 128k -ar 44100 -ac 1 -f flv"
ENCODE_COMMON_CPU="-c:v libx264 -b:v 2048k -preset veryfast -c:a aac -ab 128k -ar 44100 -ac 1 -dts_delta_threshold 1000 -f flv"

MAX_FAILS=5           # Máximo número de caídas antes de pausar relanzamiento
FAIL_WINDOW=600       # Tiempo ventana para contar caídas (segundos)
declare -A FAIL_HISTORY
MAX_LOG_LINES=2000    # Máximo de líneas permitidas en cada log de canal
MAX_LOG_SIZE=81920    # Máximo tamaño del log (80KB)

###############################################################################
# FUNCION: limitar_log
# Recorta el log si supera número de líneas o tamaño máximo.
# Evita crecimiento excesivo de archivos y pérdida de rendimiento.
###############################################################################
limitar_log() {
    local log_file="$1"
    if [[ -f "$log_file" ]]; then
        local filesize lines
        filesize=$(stat --format="%s" "$log_file")
        lines=$(wc -l < "$log_file")
        if (( lines > MAX_LOG_LINES )); then
            tail -n $MAX_LOG_LINES "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
        fi
        filesize=$(stat --format="%s" "$log_file")
        if (( filesize > MAX_LOG_SIZE )); then
            tail -c $MAX_LOG_SIZE "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
        fi
    fi
}

###############################################################################
# FUNCION: detectar_audio_spa_relativo
# Busca el primer stream de audio con idioma español ("spa") y retorna su índice.
# Si no lo encuentra, retorna 0 (primera pista de audio).
###############################################################################
detectar_audio_spa_relativo() {
    local udp_url="$1"
    ffprobe -v error -show_streams -select_streams a "$udp_url" 2>/dev/null |
    awk -F= '
        /^index=/ { stream_idx=$2 }
        /^TAG:language=spa$/ { print idx_found; found=1 }
        /^codec_type=audio$/ { idx_found=idx++; }
        END { if (!found) print 0 }
    '
}

###############################################################################
# FUNCION: detectar_codec_video
# Devuelve el nombre del codec de video principal para el canal UDP.
# Usado para elegir decodificador HW adecuado.
###############################################################################
detectar_codec_video() {
    local udp_url="$1"
    ffprobe -v error -show_streams -select_streams v "$udp_url" 2>/dev/null | awk -F= '/^codec_name=/{print $2; exit}'
}

###############################################################################
# FUNCION: lanzar_canal
# Lanza el proceso ffmpeg para un canal UDP específico según configuración.
# Elige encoder, decodificador, filtros, mapeo de audio y gestiona logs.
# Evita duplicidad de procesos ffmpeg.
###############################################################################
lanzar_canal() {
    local udp_url="$1"
    local canal_nombre="$2"
    local extra_params="$3"
    local rtmp_url="$RTMP_PREFIX/$canal_nombre"
    local log_file="$LOG_DIR/$canal_nombre.log"
    local encoder="nvenc"
    local ffmpeg_common=""
    local encode_common=""
    local filtro_opt=""
    local map_opt=""
    local user_map=""
    local audio_idx=""

    # Procesa parámetros personalizados desde canales.txt
    if [[ -n "$extra_params" ]]; then
        IFS=',' read -ra kvs <<< "$extra_params"
        for kv in "${kvs[@]}"; do
            kv="$(echo "$kv" | xargs)"
            case "$kv" in
                nodeint=1) ffmpeg_common="${ffmpeg_common/-deint 1 -drop_second_field 1/}" ;; 
                map=*) user_map="${kv#map=}" ;; 
                filtros=*) filtro_opt="${kv#filtros=}" ;; 
                encoder=qsv) encoder="qsv" ;; 
                encoder=nvenc) encoder="nvenc" ;; 
                encoder=cpu) encoder="cpu" ;; 
                encoder=vaapi) encoder="vaapi" ;; 
            esac
        done
    fi

    video_codec=$(detectar_codec_video "$udp_url")

    # Configuración por encoder
    if [[ "$encoder" == "cpu" ]]; then
        ffmpeg_common="-y -vsync 0"
        filtro_opt='-vf yadif,scale=1280:720'
        encode_common="$ENCODE_COMMON_CPU"
    elif [[ "$encoder" == "qsv" ]]; then
        # QSV hardware: decodifica y escala con hardware usando scale_qsv
        filtro_opt='-vf scale_qsv=w=1280:h=720'
        encode_common="$ENCODE_COMMON_QSV"
        if [[ "$video_codec" == "mpeg2video" ]]; then
            ffmpeg_common="-y -vsync 0 -hwaccel qsv -hwaccel_output_format qsv -c:v mpeg2_qsv"
        elif [[ "$video_codec" == "h264" ]]; then
            ffmpeg_common="-y -vsync 0 -hwaccel qsv -hwaccel_output_format qsv -c:v h264_qsv"
        else
            ffmpeg_common="-y -vsync 0 -hwaccel qsv -hwaccel_output_format qsv"
        fi
    elif [[ "$encoder" == "vaapi" ]]; then
        encode_common="$ENCODE_COMMON_VAAPI"
        if [[ "$video_codec" == "mpeg2video" ]]; then
            ffmpeg_common="-y -vsync 0 -hwaccel vaapi -c:v mpeg2_vaapi"
        elif [[ "$video_codec" == "h264" ]]; then
            ffmpeg_common="-y -vsync 0 -hwaccel vaapi -c:v h264_vaapi"
        else
            ffmpeg_common="-y -vsync 0 -hwaccel vaapi"
        fi
    else
        encode_common="$ENCODE_COMMON_NVENC"
        if [[ "$video_codec" == "mpeg2video" ]]; then
            ffmpeg_common="-y -vsync 0 -hwaccel cuda -c:v mpeg2_cuvid -deint 1 -drop_second_field 1 -resize 1280x720"
        elif [[ "$video_codec" == "h264" ]]; then
            ffmpeg_common="-y -vsync 0 -hwaccel cuda -c:v h264_cuvid -deint 1 -drop_second_field 1 -resize 1280x720"
        else
            ffmpeg_common="-y -vsync 0"
        fi
    fi

    # Audio español o mapa custom
    if [[ -n "$user_map" ]]; then
        map_opt="$user_map"
    else
        audio_idx=$(detectar_audio_spa_relativo "$udp_url")
        map_opt="-map 0:v -map 0:a:$audio_idx"
    fi

    local filtro_final=""
    if [[ -n "$filtro_opt" ]]; then
        filtro_final="$filtro_opt"
    fi

    local ffmpeg_cmd="ffmpeg $ffmpeg_common -i \"$udp_url\" $filtro_final $encode_common $map_opt \"$rtmp_url\""

    # Elimina procesos duplicados
    local pids
    pids=$(pgrep -f "$rtmp_url")
    if [[ -n "$pids" ]]; then
        local count=$(echo "$pids" | wc -l)
        if (( count > 1 )); then
            local keep_pid=$(echo "$pids" | head -n1)
            local kill_pids=$(echo "$pids" | tail -n +2)
            for pid in $kill_pids; do
                kill -9 "$pid"
                echo "
$(date '+%Y-%m-%d %H:%M:%S') [WARN] Proceso duplicado ffmpeg (PID $pid) para $canal_nombre eliminado." >> "$log_file"
                limitar_log "$log_file"
            done
            echo "
$(date '+%Y-%m-%d %H:%M:%S') [INFO] Proceso ffmpeg principal (PID $keep_pid) para $canal_nombre permanece activo." >> "$log_file"
            limitar_log "$log_file"
        else
            return
        fi
    fi

    # Diagnóstico previo
    echo "
$(date '+%Y-%m-%d %H:%M:%S') [INFO] Diagnóstico previo UDP con ffprobe..." >> "$log_file"
    limitar_log "$log_file"
    timeout 8 ffprobe "$udp_url" >> "$log_file" 2>&1 || \
        echo "
$(date '+%Y-%m-%d %H:%M:%S') [WARN] ffprobe no pudo acceder a fuente UDP." >> "$log_file"
    limitar_log "$log_file"

    # Estado de recursos
    echo "
$(date '+%Y-%m-%d %H:%M:%S') [INFO] Estado RAM/disco/GPU:" >> "$log_file"
    limitar_log "$log_file"
    free -h >> "$log_file"
    limitar_log "$log_file"
    df -h >> "$log_file"
    limitar_log "$log_file"
    command -v nvidia-smi &>/dev/null && nvidia-smi >> "$log_file"
    limitar_log "$log_file"

    # Lanza ffmpeg
    echo "
$(date '+%Y-%m-%d %H:%M:%S') [INFO] Lanzando ffmpeg para $canal_nombre: $ffmpeg_cmd" >> "$log_file"
    limitar_log "$log_file"
    nohup bash -c "$ffmpeg_cmd" >> "$log_file" 2>&1 &
    sleep 1
}

###############################################################################
# FUNCION: leer_canales
# Lee el archivo canales.txt y carga la configuración de cada canal en un array.
# Ignora líneas vacías y comentarios.
###############################################################################
leer_canales() {
    canales=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS='|' read -r udp_url canal_nombre extra_params <<< "$line"
        udp_url="$(echo "$udp_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        canal_nombre="$(echo "$canal_nombre" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        extra_params="$(echo "$extra_params" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        canales+=("$udp_url|$canal_nombre|$extra_params")
    done < "$CANALES_FILE"
}

###############################################################################
# FUNCION: lanzar_todos_canales
# Lanza todos los canales configurados al arranque del script.
###############################################################################
lanzar_todos_canales() {
    for entry in "${canales[@]}"; do
        IFS='|' read -r udp_url canal_nombre extra_params <<< "$entry"
        lanzar_canal "$udp_url" "$canal_nombre" "$extra_params"
    done
}

###############################################################################
# FUNCION: supervisar_canales
# Revisa periódicamente si los procesos ffmpeg están activos.
# Relanza automáticamente si algún canal se cae, aplicando tolerancia a fallos.
###############################################################################
supervisar_canales() {
    while true; do
        for entry in "${canales[@]}"; do
            IFS='|' read -r udp_url canal_nombre extra_params <<< "$entry"
            rtmp_url="$RTMP_PREFIX/$canal_nombre"
            log_file="$LOG_DIR/$canal_nombre.log"
            if ! pgrep -f "$rtmp_url" > /dev/null; then
                now=$(date +%s)
                FAIL_HISTORY["$canal_nombre"]+="$now "
                fails=0
                for ts in ${FAIL_HISTORY["$canal_nombre"]}; do
                    (( now - ts <= FAIL_WINDOW )) && ((fails++))
                done
                if (( fails > MAX_FAILS )); then
                    echo "
$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Canal $canal_nombre cayó $fails veces en los últimos $FAIL_WINDOW segundos. Pausando relanzamiento por 10 minutos." >> "$log_file"
                    limitar_log "$log_file"
                    sleep 600
                    continue
                fi
                echo "
$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Canal $canal_nombre caído. Relanzando..." >> "$log_file"
                limitar_log "$log_file"
                lanzar_canal "$udp_url" "$canal_nombre" "$extra_params"
                echo "
$(date '+%Y-%m-%d %H:%M:%S') [INFO] Canal $canal_nombre relanzado por supervisor." >> "$log_file"
                limitar_log "$log_file"
            fi
        done
        sleep 60
    done
}

###############################################################################
# FUNCION: relanzar_canal_por_nombre
# Permite relanzar manualmente un canal por nombre desde la terminal.
# Útil para recuperar canales sin reiniciar todo.
###############################################################################
relanzar_canal_por_nombre() {
    local nombre="$1"
    leer_canales
    local encontrado=0
    for entry in "${canales[@]}"; do
        IFS='|' read -r udp_url canal_nombre extra_params <<< "$entry"
        if [[ "$canal_nombre" == "$nombre" ]]; then
            encontrado=1
            echo "Relanzando canal: $canal_nombre"
            local rtmp_url="$RTMP_PREFIX/$canal_nombre"
            local log_file="$LOG_DIR/$canal_nombre.log"
            local pids
            pids=$(pgrep -f "$rtmp_url")
            if [[ -n "$pids" ]]; then
                for pid in $pids; do
                    kill -9 "$pid"
                    echo "Proceso ffmpeg (PID $pid) para $canal_nombre eliminado."
                    echo "
$(date '+%Y-%m-%d %H:%M:%S') [WARN] Proceso ffmpeg (PID $pid) para $canal_nombre eliminado manualmente." >> "$log_file"
                    limitar_log "$log_file"
                done
                sleep 1
            fi
            lanzar_canal "$udp_url" "$canal_nombre" "$extra_params"
            echo "Canal $canal_nombre relanzado manualmente."
            echo "
$(date '+%Y-%m-%d %H:%M:%S') [INFO] Canal $canal_nombre relanzado manualmente." >> "$log_file"
            limitar_log "$log_file"
            return 0
        fi
    done
    if [[ $encontrado -eq 0 ]]; then
        echo "Canal '$nombre' no encontrado en canales.txt"
        return 1
    fi
}

###############################################################################
# ENTRADA PRINCIPAL DEL SCRIPT
# Si se invoca con argumento relanzar <canal>, relanza sólo ese canal.
# Si no, lanza todos los canales y activa supervisor automático.
###############################################################################
if [[ "$1" == "relanzar" && -n "$2" ]]; then
    relanzar_canal_por_nombre "$2"
    exit $?
fi

if [[ ! -f "$CANALES_FILE" ]]; then
    echo "ERROR: No se encontró el archivo canales.txt en $SCRIPT_DIR"
    exit 1
fi

leer_canales
lanzar_todos_canales
supervisar_canales

exit 0
