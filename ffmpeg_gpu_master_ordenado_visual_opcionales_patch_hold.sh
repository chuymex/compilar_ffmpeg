#!/bin/bash

#############################################################
# Script Master FFmpeg + GPU Drivers + Utilidades + Pruebas #
#############################################################
# Descripción general:
# - Instala dependencias y librerías necesarias para FFmpeg y codecs avanzados.
# - Detecta GPUs (NVIDIA, INTEL, AMD) y realiza instalación idempotente de drivers.
# - Instala utilidades para monitoreo y administración GPU.
# - Compila FFmpeg si no está presente, activando soporte HW correspondiente.
# - Realiza pruebas automáticas de aceleración HW.
# - Aplica el parche nvidia-patch para desbloquear encoders NVIDIA (solo si no fue aplicado antes).
# - Pone en hold los drivers NVIDIA y el kernel para evitar actualizaciones que dañen la instalación.
# - Guarda logs visuales en /root/resultado_instalacion.txt.
#
# Lógica:
# - Verifica si cada paquete está instalado antes de instalar.
# - Marca como error solo fallos críticos (drivers, FFmpeg, pruebas HW).
# - Los paquetes opcionales no detienen el proceso si no existen, solo muestran advertencia.
# - Muestra al final un resumen de paquetes opcionales omitidos.
# - Reinicio solo si es necesario (por Nouveau), usando flag para evitar ciclos infinitos.
#############################################################

LOG_FILE="/root/resultado_instalacion.txt"
REBOOT_FLAG="/root/.gpu_script_rebooted.flag"
SUCCESS=true
OPCIONAL_FALTANTES=()

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # sin color

exec > >(tee -a "$LOG_FILE") 2>&1

log_mod() {
  echo -e "\n${BLUE}========== $1 ==========${NC}\n"
}

log_ok() {
  echo -e "${GREEN}✔ $1${NC}"
}

log_err() {
  echo -e "${RED}✖ $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

log_ver() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

# -------------------------------------------
# 1. INSTALAR DEPENDENCIAS
# -------------------------------------------
log_mod "[1. INSTALACION DE DEPENDENCIAS FFmpeg y HW]"
# NOTA: libopenjpeg-dev NO existe en Ubuntu 24.04+, usar libopenjp2-7-dev
DEPENDENCIES=(build-essential pkg-config git yasm cmake libx264-dev libx265-dev libnuma-dev libvpx-dev libopus-dev libfdk-aac-dev libass-dev libfreetype6-dev libvorbis-dev libmp3lame-dev libxcb-shm0-dev libxcb-xfixes0-dev libdrm-dev libva-dev vainfo libmfx-dev libvdpau-dev libaom-dev libsvtav1-dev libsoxr-dev libspeex-dev libwebp-dev libopenjp2-7-dev ocl-icd-opencl-dev python3-dev python3-pip linux-headers-$(uname -r))

# Paquetes críticos y opcionales
CRITICOS=(build-essential pkg-config git yasm cmake libx264-dev libx265-dev libnuma-dev libvpx-dev libopus-dev libfdk-aac-dev libass-dev libfreetype6-dev libvorbis-dev libmp3lame-dev libdrm-dev libva-dev vainfo libmfx-dev libvdpau-dev libaom-dev python3-dev python3-pip linux-headers-$(uname -r))
OPCIONALES=(libsvtav1-dev libsoxr-dev libspeex-dev libwebp-dev libopenjp2-7-dev ocl-icd-opencl-dev libxcb-shm0-dev libxcb-xfixes0-dev)

for pkg in "${DEPENDENCIES[@]}"; do
  if dpkg -s "$pkg" &>/dev/null; then
    log_ok "[$pkg] ya instalado."
  else
    log_warn "[$pkg] Instalando..."
    if sudo apt-get install -y "$pkg"; then
      log_ok "[$pkg] instalado OK."
    else
      if [[ " ${CRITICOS[@]} " =~ " $pkg " ]]; then
        log_err "[$pkg] ERROR al instalar."
        SUCCESS=false
      else
        log_warn "[$pkg] NO encontrado, puede ser opcional o no crítico."
        OPCIONAL_FALTANTES+=("$pkg")
      fi
    fi
  fi
... [TRUNCATED; full file will be pushed]