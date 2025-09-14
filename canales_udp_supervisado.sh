#!/bin/bash

###############################################################################
# Script: canales_udp_supervisado.sh
# Descripción: Inicia, supervisa y relanza canales UDP a RTMP con control de duplicados y protección contra supervisores huérfanos.
# Autor: chuymex
# Última modificación: 2025-09-14
###############################################################################

# ======================== CONFIGURACIÓN GLOBAL ===============================
TIMEOUT=10                               # Timeout (segundos) para ffprobe/ffmpeg
RELAUNCH_DELAY=10                        # Delay global (segundos) entre relanzamientos ffmpeg
SUPERVISOR_CHECK_INTERVAL=5              # Intervalo (segundos) para chequeo activo del supervisor de ffmpeg
MAX_LOG_LINES=2000                       # Máx líneas por log
MAX_LOG_SIZE=81920                       # Máx tamaño por log (bytes)
ERROR_MAX_REPEAT=5                       # Máx repeticiones de una línea de error en el log resumido
SCRIPT_DIR="$(cd \"$(dirname \"$0\")\" && pwd)" # Obtiene el directorio donde está el script
LOG_DIR="$SCRIPT_DIR/logs"               # Carpeta para logs por canal
CANALES_FILE="$SCRIPT_DIR/canales.txt"   # Archivo de configuración de canales
RTMP_PREFIX="rtmp://fuentes.futuretv.pro:9922/tp" # Prefijo RTMP destino

# Parámetros comunes de codificación para cada tipo de encoder
ENCODE_COMMON_NVENC="-c:v h264_nvenc -b:v 2M -bufsize 4M -preset p2 -tune 3 -g 60 -c:a aac -dts_delta_threshold 1000 -ab 128k -ar 44100 -ac 1 -f flv"
ENCODE_COMMON_QSV="-c:v h264_qsv -b:v 2048k -preset medium -c:a aac -ab 128k -ar 44100 -ac 1 -dts_delta_threshold 1000 -f flv"
ENCODE_COMMON_VAAPI="-c:v h264_vaapi -b:v 2M -preset fast -c:a aac -dts_delta_threshold 1000 -ab 128k -ar 44100 -ac 1 -f flv"
ENCODE_COMMON_CPU="-c:v libx264 -b:v 2048k -preset veryfast -c:a aac -ab 128k -ar 44100 -ac 1 -dts_delta_threshold 1000 -f flv"

# ======================== COLORES E ICONOS PARA LOGS =========================
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
NC="\033[0m"
ICON_OK="✅"
ICON_ERR="❌"
ICON_WARN="⚠️"
ICON_INFO="ℹ️"
ICON_ALERT="🚨"

# ======================== FUNCIONES DE LOGGING ===============================
# Limita tamaño y líneas del log para evitar crecimiento descontrolado
limitar_log() {
    local log_file="$1"
    if [[ -f "$log_file" ]]; then
        local filesize lines
        filesize=$(stat --format="%s" "$log_file")
        lines=$(wc -l < "$log_file")
        # Limita líneas máximas
        if (( lines > MAX_LOG_LINES )); then
            tail -n $MAX_LOG_LINES "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
        fi
        filesize=$(stat --format="%s" "$log_file")
        # Limita tamaño máximo en bytes
        if (( filesize > MAX_LOG_SIZE )); then
            tail -c $MAX_LOG_SIZE "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
        fi
    fi
}

# Muestra un resumen filtrado del log, suprime errores repetidos según ERROR_MAX_REPEAT
mostrar_log_resumido() {
    local log_file="$1"
    local tipo="$2"
    local icon=""
    local color=""
    case "$tipo" in
        ERROR) icon="$ICON_ERR"; color="$RED";;
        WARN) icon="$ICON_WARN"; color="$YELLOW";;
        ALERT) icon="$ICON_ALERT"; color="$BLUE";;
        *) icon="$ICON_INFO"; color="$NC";;
    esac
    # Filtra y limita repeticiones de cada línea de tipo (ERROR, WARN, ALERT)
    awk -v max="$ERROR_MAX_REPEAT" -v icon="$icon" -v color="$color" -v nc="$NC" -v tipo="$tipo" '
        $0 ~ ("\\["tipo"\\]") {
            rep[$0]++
            if (rep[$0]<=max) print color icon " " $0 nc
            else if (rep[$0]==max+1) print color icon " ... (más repeticiones ocultas)" nc
        }
    ' "$log_file"
}

# ======================== FUNCIONES DE DETECCIÓN DE STREAMS ==================
# Detecta el índice de audio preferente (spa/aac/mp2/ac3) en UDP
detectar_audio_spa_preferencia() {
    local udp_url="$1"
    timeout $TIMEOUT ffprobe -v error -show_streams -select_streams a "$udp_url" 2>/dev/null | \
    awk -F= '
        BEGIN { aac_idx=""; mp2_idx=""; ac3_idx=""; spa_idx=""; first_idx="" }
        /^index=/      { idx=
$2 }
        /^codec_name=aac$/  { codec_aac=1 }
        /^codec_name=mp2$/  { codec_mp2=1 }
        /^codec_name=ac3$/  { codec_ac3=1 }
        /^TAG:language=spa$/ {
            if (codec_aac && aac_idx == "") aac_idx=idx;
            if (codec_mp2 && mp2_idx == "") mp2_idx=idx;
            if (codec_ac3 && ac3_idx == "") ac3_idx=idx;
            if (spa_idx == "") spa_idx=idx;
        }
        /^codec_type=audio$/ { if (first_idx == "") first_idx=idx }
        /^codec_name=/ { codec_aac=($2=="aac"); codec_mp2=($2=="mp2"); codec_ac3=($2=="ac3") }
        END {
            if (aac_idx != "") print aac_idx;
            else if (mp2_idx != "") print mp2_idx;
            else if (ac3_idx != "") print ac3_idx;
            else if (spa_idx != "") print spa_idx;
            else if (first_idx != "") print first_idx;
            else print 0;
        }
    '
}

# Obtiene el parámetro -map válido según fuente UDP para ffmpeg
get_valid_audio_map() {
    local udp_url="$1"
    local idx
    idx=$(detectar_audio_spa_preferencia "$udp_url")
    idx=$(echo "$idx" | tr -d '\n')
    timeout $TIMEOUT ffmpeg -hide_banner -nostats -v error -i "$udp_url" -map 0:a:"$idx" -f null - 2>&1 | grep -q "Stream map '' matches no streams"
    local status=$?
    if [[ $status -eq 0 ]]; then
        echo "-map 0:v -map 0:a:0"
    else
        echo "-map 0:v -map 0:a:$idx"
    fi
}

# Detecta el codec de video de la fuente UDP
detectar_codec_video() {
    local udp_url="$1"
    timeout $TIMEOUT ffprobe -v error -show_streams -select_streams v "$udp_url" 2>/dev/null | awk -F= '/^codec_name=/{print $2; exit}'
}

# =================== PROTECCIÓN CONTRA DUPLICADOS Y HUÉRFANOS ===============
# Verifica si hay un supervisor activo para el canal (por log_file)
supervisor_activo() {
    local canal_nombre="$1"
    local log_file="$LOG_DIR/$canal_nombre.log"
    pgrep -af "supervisor_ffmpeg.sh" | grep "$log_file" | grep -v grep > /dev/null
}

# Verifica si ffmpeg está activo para el canal (por rtmp y udp)
ffmpeg_activo() {
    local rtmp_url="$1"
    local udp_url="$2"
    pgrep -af "ffmpeg" | grep "$rtmp_url" | grep "$udp_url" | grep -v grep > /dev/null
}

# Limpia supervisores huérfanos si no hay proceso ffmpeg activo para el canal
limpiar_supervisor_huerfano() {
    local canal_nombre="$1"
    local log_file="$LOG_DIR/$canal_nombre.log"
    if supervisor_activo "$canal_nombre"; then
        local pid_sup
        pid_sup=$(pgrep -af "supervisor_ffmpeg.sh" | grep "$log_file" | awk '{print $1}')
        local rtmp_url="$RTMP_PREFIX/$canal_nombre"
        local udp_url
        udp_url=$(grep -m1 "Fuente UDP:" "$log_file" | awk -F': ' '{print $2}')
        if ! ffmpeg_activo "$rtmp_url" "$udp_url"; then
            echo "[WARN] $ICON_WARN Supervisor huérfano detectado para $canal_nombre (pid $pid_sup), terminando..." >> "$log_file"
            kill "$pid_sup"
        fi
    fi
}

# =================== LANZAMIENTO DE CANAL CON LOG DETALLADO ===================
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
    local force_map0="no"
    local relaunch_delay="$RELAUNCH_DELAY"
    local quitar_deint="no"

    # Logging inicial del canal
    echo "=============================================" > "$log_file"
    echo "[INFO] $ICON_INFO Lanzando canal: $canal_nombre" >> "$log_file"
    echo "[INFO] $ICON_INFO Fecha/hora inicio: $(date)" >> "$log_file"
    echo "[INFO] $ICON_INFO Fuente UDP: $udp_url" >> "$log_file"
    echo "[INFO] $ICON_INFO RTMP destino: $rtmp_url" >> "$log_file"
    echo "[INFO] $ICON_INFO Parámetros extra: $extra_params" >> "$log_file"
    echo "=============================================" >> "$log_file"

    # Parseo de parámetros extra personalizados por canal
    if [[ -n "$extra_params" ]]; then
        IFS=',' read -ra kvs <<< "$extra_params"
        for kv in "${kvs[@]}"; do
            kv="$(echo "$kv" | xargs)"
            case "$kv" in
                nodeint=1) quitar_deint="si" ;;
                map=0) force_map0="yes" ;;
                map=*) user_map="${kv#map=}" ;;
                filtros=*) filtro_opt="${kv#filtros=}" ;;
                encoder=qsv) encoder="qsv" ;;
                encoder=nvenc) encoder="nvenc" ;;
                encoder=cpu) encoder="cpu" ;;
                encoder=vaapi) encoder="vaapi" ;;
                delay=*) relaunch_delay="${kv#delay=}" ;;
            esac
        done
    fi

    # Detección automática de codec de video en fuente UDP
    local video_codec
    video_codec=$(detectar_codec_video "$udp_url")
    if [[ -z "$video_codec" ]]; then
        echo "[ERROR] $ICON_ERR No se pudo detectar el codec de video. Verifica la fuente UDP ($udp_url)." >> "$log_file"
        echo "[ERROR] $ICON_ERR El canal no será lanzado por error de fuente." >> "$log_file"
        return
    fi
    echo "[INFO] $ICON_INFO Codec de video detectado: $video_codec" >> "$log_file"

    # Selección de mapeo de audio
    if [[ "$force_map0" == "yes" ]]; then
        map_opt="-map 0:v -map 0:a:0"
        echo "[INFO] $ICON_INFO Mapeo de audio forzado: $map_opt" >> "$log_file"
    elif [[ -n "$user_map" ]]; then
        map_opt="$user_map"
        echo "[INFO] $ICON_INFO Mapeo de audio personalizado: $map_opt" >> "$log_file"
    else
        map_opt=$(get_valid_audio_map "$udp_url")
        echo "[INFO] $ICON_INFO Mapeo de audio automático: $map_opt" >> "$log_file"
    fi

    # Construcción de parámetros ffmpeg según encoder y fuente
    case "$encoder" in
        cpu)
            ffmpeg_common="-y -vsync 0"
            filtro_opt='-vf yadif,scale=1280:720'
            encode_common="$ENCODE_COMMON_CPU"
            ;;
        qsv)
            filtro_opt='-vf scale_qsv=w=1280:h=720'
            encode_common="$ENCODE_COMMON_QSV"
            if [[ "$video_codec" == "mpeg2video" ]]; then
                ffmpeg_common="-y -vsync 0 -hwaccel qsv -hwaccel_output_format qsv -c:v mpeg2_qsv"
            elif [[ "$video_codec" == "h264" ]]; then
                ffmpeg_common="-y -vsync 0 -hwaccel qsv -hwaccel_output_format qsv -c:v h264_qsv"
            else
                ffmpeg_common="-y -vsync 0 -hwaccel qsv -hwaccel_output_format qsv"
            fi
            ;;
        vaapi)
            encode_common="$ENCODE_COMMON_VAAPI"
            if [[ "$video_codec" == "mpeg2video" ]]; then
                ffmpeg_common="-y -vsync 0 -hwaccel vaapi -c:v mpeg2_vaapi"
            elif [[ "$video_codec" == "h264" ]]; then
                ffmpeg_common="-y -vsync 0 -hwaccel vaapi -c:v h264_vaapi"
            else
                ffmpeg_common="-y -vsync 0 -hwaccel vaapi"
            fi
            ;;
        *)
            encode_common="$ENCODE_COMMON_NVENC"
            if [[ "$video_codec" == "mpeg2video" ]]; then
                ffmpeg_common="-y -vsync 0 -hwaccel cuda -c:v mpeg2_cuvid"
                if [[ "$quitar_deint" != "si" ]]; then
                    ffmpeg_common="$ffmpeg_common -deint 1 -drop_second_field 1"
                fi
                ffmpeg_common="$ffmpeg_common -resize 1280x720"
            elif [[ "$video_codec" == "h264" ]]; then
                ffmpeg_common="-y -vsync 0 -hwaccel cuda -c:v h264_cuvid"
                if [[ "$quitar_deint" != "si" ]]; then
                    ffmpeg_common="$ffmpeg_common -deint 1 -drop_second_field 1"
                fi
                ffmpeg_common="$ffmpeg_common -resize 1280x720"
            else
                ffmpeg_common="-y -vsync 0"
            fi
            ;;
    esac

    local filtro_final=""
    [[ -n "$filtro_opt" ]] && filtro_final="$filtro_opt"
    local ffmpeg_cmd="ffmpeg $ffmpeg_common -i \"$udp_url\" $filtro_final $encode_common $map_opt \"$rtmp_url\""
    echo "[INFO] $ICON_INFO Comando ffmpeg preparado:" >> "$log_file"
    echo "$ffmpeg_cmd" >> "$log_file"

    # Antes de lanzar, limpia supervisores huérfanos y protege duplicados
    limpiar_supervisor_huerfano "$canal_nombre"

    if supervisor_activo "$canal_nombre"; then
        echo "[WARN] $ICON_WARN Ya existe supervisor activo para $canal_nombre, no se lanza otro." >> "$log_file"
    else
        echo "[INFO] $ICON_INFO Lanzando supervisor ffmpeg para canal: $canal_nombre" >> "$log_file"
        nohup "$SCRIPT_DIR/supervisor_ffmpeg.sh" "$ffmpeg_cmd" "$log_file" "$relaunch_delay" "$SUPERVISOR_CHECK_INTERVAL" >/dev/null 2>&1 &
        echo "[INFO] $ICON_OK Canal lanzado en segundo plano y supervisado." >> "$log_file"
    fi
    limitar_log "$log_file"
}

# =================== LECTURA DE CANALES DESDE ARCHIVO ========================
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

# =================== LANZAMIENTO DE TODOS LOS CANALES ========================
lanzar_todos_canales() {
    for entry in "${canales[@]}"; do
        IFS='|' read -r udp_url canal_nombre extra_params <<< "$entry"
        lanzar_canal "$udp_url" "$canal_nombre" "$extra_params"
    done
}

# =================== FUNCIONES DE RELANZAMIENTO MANUAL ======================
relanzar_canal_forzado() {
    local canal_nombre="$1"
    local encontrado="no"

    leer_canales
    for entry in "${canales[@]}"; do
        IFS='|' read -r udp_url nombre extra_params <<< "$entry"
        if [[ "$nombre" == "$canal_nombre" ]]; then
            local rtmp_url="$RTMP_PREFIX/$canal_nombre"
            local log_file="$LOG_DIR/$canal_nombre.log"
            # Termina ffmpeg y supervisores activos para el canal
            echo -e "${GREEN}$ICON_ALERT Terminando procesos ffmpeg y supervisores para canal '$canal_nombre'...${NC}"
            pkill -f "ffmpeg.*$rtmp_url"
            pkill -f "supervisor_ffmpeg.sh.*$log_file"
            sleep 2

            if [[ -f "$log_file" ]]; then
                echo -e "${GREEN}$ICON_INFO Eliminando log: $log_file${NC}"
                rm -f "$log_file"
            else
                echo -e "${GREEN}$ICON_INFO No existe log previo para canal '$canal_nombre'.${NC}"
            fi

            echo -e "${GREEN}$ICON_INFO Relanzando canal '$canal_nombre'...${NC}"
            lanzar_canal "$udp_url" "$canal_nombre" "$extra_params"

            if [[ -f "$log_file" ]]; then
                if grep -q "\[ERROR\]" "$log_file"; then
                    echo -e "${RED}---------------------------------------------"
                    echo -e "$ICON_ERR ¡¡¡ ERROR AL INICIAR CANAL '$canal_nombre' !!!"
                    echo -e "Resumen de errores encontrados (máx $ERROR_MAX_REPEAT por tipo):"
                    mostrar_log_resumido "$log_file" "ERROR"
                    mostrar_log_resumido "$log_file" "WARN"
                    mostrar_log_resumido "$log_file" "ALERT"
                    echo -e "---------------------------------------------"
                    echo -e "Log completo del canal '$canal_nombre':"
                    cat "$log_file"
                    echo -e "---------------------------------------------${NC}"
                else
                    echo -e "${GREEN}$ICON_OK Canal '$canal_nombre' relanzado exitosamente.${NC}"
                    echo -e "${YELLOW}$ICON_INFO Resumen del log (últimas 20 líneas):${NC}"
                    tail -n 20 "$log_file"
                    echo -e "${YELLOW}---------------------------------------------${NC}"
                fi
            else
                echo -e "${RED}$ICON_ERR No se generó log para el canal '$canal_nombre'.${NC}"
            fi
            encontrado="si"
            break
        fi
    done
    if [[ "$encontrado" == "no" ]]; then
        echo -e "${RED}$ICON_ERR Canal '$canal_nombre' no encontrado en canales.txt${NC}"
        exit 1
    fi
}

# ======================== MAIN DEL SCRIPT ====================================
mkdir -p "$LOG_DIR"
# find "$LOG_DIR" -type f -name "*.log" -delete   # ← NO BORRAR LOGS EN BLOQUE

if [[ "$1" == "relanzar" && -n "$2" ]]; then
    relanzar_canal_forzado "$2"
    exit 0
fi

if [[ ! -f "$CANALES_FILE" ]]; then
    echo "ERROR: No se encontró el archivo canales.txt en $SCRIPT_DIR"
    exit 1
fi

leer_canales
lanzar_todos_canales

exit 0
