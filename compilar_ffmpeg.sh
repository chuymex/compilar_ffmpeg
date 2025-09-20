#!/bin/bash

####################################################################################################
# Script Master FFmpeg + GPU Drivers + Utilidades + Pruebas + Protección Actualizaciones           #
####################################################################################################
# Descripción general:
# - Instala y compila FFmpeg con soporte para NVIDIA e Intel.
# - Detecta y elimina Nouveau si está presente, con reinicio obligatorio.
# - Instala dependencias, drivers, utilidades, realiza pruebas y aplica parches NVIDIA.
# - Protege el sistema contra actualizaciones automáticas del kernel y drivers (apt-mark hold).
# - DESACTIVA unattended-upgrades automáticamente para evitar rompimiento del entorno.
# - Diagnósticos y logs detallados para cada paso.
# - Modular, cada sección está comentada y es fácilmente extensible.
# Autor: chuymex
####################################################################################################

####################################################################################
# [0] CONFIGURACIÓN GLOBAL Y PARÁMETROS PERSONALIZABLES                            #
# - Define variables globales, rutas, listas de paquetes y colores para logs.
# - Permite modificar fácilmente versión de driver, logs y dependencias FFmpeg.
####################################################################################
LOG_FILE="/root/resultado_instalacion.txt"
REBOOT_FLAG="/root/.gpu_script_rebooted.flag"
NVIDIA_EXPECTED="575.64.05"
SVTAV1_FLAG="--enable-libsvtav1"

DEPENDENCIES=(
  build-essential pkg-config git yasm cmake libx264-dev libx265-dev libnuma-dev libvpx-dev libopus-dev libfdk-aac-dev
  libass-dev libfreetype6-dev libvorbis-dev libmp3lame-dev libxcb-shm0-dev libxcb-xfixes0-dev libdrm-dev libva-dev
  vainfo libmfx-dev libvdpau-dev libaom-dev libsvtav1-dev libsoxr-dev libspeex-dev libwebp-dev libopenjp2-7-dev
  ocl-icd-opencl-dev python3-dev python3-pip linux-headers-$(uname -r)
)
CRITICOS=(
  build-essential pkg-config git yasm cmake libx264-dev libx265-dev libnuma-dev libvpx-dev libopus-dev libfdk-aac-dev
  libass-dev libfreetype6-dev libvorbis-dev libmp3lame-dev libdrm-dev libva-dev vainfo libmfx-dev libvdpau-dev libaom-dev
  python3-dev python3-pip linux-headers-$(uname -r)
)
OPCIONALES=(
  libsvtav1-dev libsoxr-dev libspeex-dev libwebp-dev libopenjp2-7-dev ocl-icd-opencl-dev libxcb-shm0-dev libxcb-xfixes0-dev
)
INTEL_PKGS=(libze-intel-gpu1 libze1 intel-metrics-discovery intel-opencl-icd clinfo intel-gsc intel-media-va-driver-non-free libmfx-gen1 libvpl2 libvpl-tools va-driver-all vainfo libze-dev intel-ocloc)
UTILS_PKGS=(nvidia-cuda-toolkit nvtop mc net-tools intel-gpu-tools)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SUCCESS=true
OPCIONAL_FALTANTES=()

####################################################################################
# [1] FUNCIONES DE LOG Y REINICIO                                                  #
# - Define funciones para logging con colores y para reiniciar el sistema de forma segura.
# - Redirige toda la salida a consola y archivo LOG.
####################################################################################
exec > >(tee -a "$LOG_FILE") 2>&1
log_mod()   { echo -e "\n${BLUE}========== $1 ==========${NC}\n"; }
log_ok()    { echo -e "${GREEN}✔ $1${NC}"; }
log_err()   { echo -e "${RED}✖ $1${NC}"; }
log_warn()  { echo -e "${YELLOW}⚠ $1${NC}"; }
log_info()  { echo -e "${CYAN}ℹ $1${NC}"; }

countdown_and_reboot() {
  echo ""
  echo -e "${YELLOW}$1${NC}"
  echo -e "${YELLOW}El sistema se reiniciará en 5 segundos...${NC}"
  for i in {5..1}; do
    echo -e "${YELLOW}Reinicio en $i...${NC}"
    sleep 1
  done
  echo -e "${YELLOW}¡Reiniciando ahora!${NC}"
  reboot
  exit 0
}

####################################################################################
# [2] DESINSTALACIÓN Y BLOQUEO DE NOUVEAU (DRIVER ABIERTO NVIDIA)                  #
# - Detecta si el driver abierto Nouveau está cargado.
# - Si existe, lo desinstala y lo bloquea para prevenir conflictos con NVIDIA propietario.
# - Fuerza reinicio tras la eliminación y actualización de initramfs.
####################################################################################
log_mod "[INICIO - DESINSTALACIÓN Y DESACTIVACIÓN DE NOUVEAU]"
if lsmod | grep -i nouveau &>/dev/null; then
  log_warn "[NVIDIA] Detectado el driver abierto Nouveau activo en el kernel."
  log_warn "[NVIDIA] Desinstalando y desactivando Nouveau para evitar conflictos con el driver propietario de NVIDIA."
  if dpkg -l | grep -i xserver-xorg-video-nouveau &>/dev/null; then
    log_warn "[NVIDIA] Desinstalando paquete xserver-xorg-video-nouveau..."
    sudo apt-get remove --purge -y xserver-xorg-video-nouveau
  fi
  echo -e "blacklist nouveau\noptions nouveau modeset=0" | sudo tee /etc/modprobe.d/disable-nouveau.conf
  sudo update-initramfs -u
  touch "$REBOOT_FLAG"
  countdown_and_reboot "[NVIDIA] Reinicio necesario para finalizar desinstalación y desactivación de Nouveau."
fi

####################################################################################
# [3] REMOVER HOLD DE PAQUETES (LIBERACIÓN PARA INSTALACIÓN/ACTUALIZACIÓN)         #
# - Libera los paquetes NVIDIA y del kernel de posibles bloqueos (hold).
# - Permite instalar y actualizar drivers/headers sin restricciones previas.
####################################################################################
log_mod "[REMOVIENDO HOLD DE PAQUETES NVIDIA Y KERNEL]"
if lspci | grep -i nvidia &>/dev/null; then
  for pkg in $(dpkg -l | grep nvidia | awk '{print $2}'); do
    sudo apt-mark unhold "$pkg" && log_warn "Unhold aplicado a paquete NVIDIA: $pkg"
  done
fi
KERNEL_PKG="linux-image-$(uname -r)"
KERNEL_HDR="linux-headers-$(uname -r)"
sudo apt-mark unhold "$KERNEL_PKG" && log_warn "Unhold aplicado a kernel: $KERNEL_PKG"
sudo apt-mark unhold "$KERNEL_HDR" && log_warn "Unhold aplicado a headers: $KERNEL_HDR"

####################################################################################
# [4] DETECCIÓN DE GPU (NVIDIA / INTEL)                                            #
# - Detecta automáticamente la presencia de GPU NVIDIA e Intel para instalar solo lo necesario.
####################################################################################
log_mod "[DETECCIÓN DE GPU]"
HAS_NVIDIA=false
HAS_INTEL=false
if lspci | grep -i nvidia &>/dev/null; then HAS_NVIDIA=true; fi
if lspci | grep -i 'intel' | grep -i 'graphics' &>/dev/null || vainfo | grep -i 'intel' &>/dev/null; then HAS_INTEL=true; fi

####################################################################################
# [5] INSTALACIÓN DE DEPENDENCIAS FFmpeg Y HW                                      #
# - Instala todas las dependencias críticas y opcionales para FFmpeg y GPU.
# - Actualiza paquetes si existe una versión más reciente.
# - Si algún paquete crítico falla, marca el proceso como fallido.
####################################################################################
log_mod "[INSTALACION DE DEPENDENCIAS FFmpeg y HW]"
for pkg in "${DEPENDENCIES[@]}"; do
  INSTALLED_VER=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
  CANDIDATE_VER=$(apt-cache policy "$pkg" 2>/dev/null | grep Candidate | awk '{print $2}')
  if [ -n "$INSTALLED_VER" ]; then
    if [ -n "$CANDIDATE_VER" ] && dpkg --compare-versions "$CANDIDATE_VER" gt "$INSTALLED_VER"; then
      log_warn "[$pkg] Instalado ($INSTALLED_VER), pero hay versión más reciente ($CANDIDATE_VER). Actualizando..."
      if sudo apt-get install -y "$pkg"; then
        log_ok "[$pkg] actualizado a $CANDIDATE_VER."
      else
        log_err "[$pkg] ERROR al actualizar."
      fi
    else
      log_ok "[$pkg] ya instalado en versión $INSTALLED_VER."
    fi
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
done

####################################################################################
# [6] VERIFICACIÓN DE SVT-AV1 (AV1 HW PARA FFmpeg)                                 #
# - Verifica si SVT-AV1 está instalado y disponible para FFmpeg.
# - Si no está, desactiva el flag para evitar errores de compilación.
####################################################################################
log_mod "[VERIFICACION LIBSVTAV1 SOLO POR PAQUETE DE SISTEMA]"
SVTAV1_OK=false
if pkg-config --exists SvtAv1Enc; then
  log_ok "[SVT-AV1] SVT-AV1 ya presente y detectado por pkg-config."
  SVTAV1_OK=true
else
  log_warn "[SVT-AV1] No se detecta SVT-AV1 compatible en el sistema. Compilando FFmpeg SIN soporte AV1 HW."
  SVTAV1_OK=false
  SVTAV1_FLAG=""
fi

####################################################################################
# [7] INSTALACIÓN DE DRIVERS GPU (NVIDIA / INTEL)                                  #
# - Instala los drivers propietarios NVIDIA y/o Intel si es necesario.
# - Verifica versión instalada y fuerza reinicio tras instalación.
# - En el caso Intel, añade el PPA si no existe y actualiza los paquetes clave.
####################################################################################
log_mod "[INSTALACIÓN DE DRIVERS GPU]"
if $HAS_NVIDIA; then
  NVIDIA_INSTALLED=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
  if [[ "$NVIDIA_INSTALLED" == "$NVIDIA_EXPECTED" ]]; then
    log_ok "[NVIDIA] Driver $NVIDIA_EXPECTED ya instalado."
  else
    log_warn "[NVIDIA] Instalando driver NVIDIA $NVIDIA_EXPECTED..."
    sudo apt-get remove --purge -y "*nvidia*" && log_ok "[NVIDIA] Drivers previos removidos."
    sudo apt-get autoremove -y
    sudo rm -rf /etc/modprobe.d/*nvidia*
    sudo rm -rf /etc/X11/xorg.conf
    wget -O /root/NVIDIA-Linux-x86_64-$NVIDIA_EXPECTED.run "https://international.download.nvidia.com/XFree86/Linux-x86_64/$NVIDIA_EXPECTED/NVIDIA-Linux-x86_64-$NVIDIA_EXPECTED.run" \
      && log_ok "[NVIDIA] Driver descargado OK." || { log_err "[NVIDIA] ERROR descarga driver."; SUCCESS=false; }
    chmod +x /root/NVIDIA-Linux-x86_64-$NVIDIA_EXPECTED.run
    sudo systemctl isolate multi-user.target
    sudo /root/NVIDIA-Linux-x86_64-$NVIDIA_EXPECTED.run --silent --no-drm --dkms --install-libglvnd \
      && log_ok "[NVIDIA] Driver instalado OK." || { log_err "[NVIDIA] ERROR al instalar driver."; SUCCESS=false; }
    NVIDIA_INSTALLED=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    if [[ "$NVIDIA_INSTALLED" == "$NVIDIA_EXPECTED" ]]; then
      log_ok "[NVIDIA] Instalación verificada. Driver $NVIDIA_EXPECTED activo."
    else
      log_err "[NVIDIA] Driver esperado NO activo tras instalación."
      SUCCESS=false
    fi
    touch "$REBOOT_FLAG"
    countdown_and_reboot "[NVIDIA] Reinicio necesario tras instalación de driver NVIDIA para evitar conflictos."
  fi
fi

if $HAS_INTEL; then
  if ! grep -q "kobuk-team/intel-graphics" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    log_warn "[INTEL] Agregando PPA kobuk-team/intel-graphics..."
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:kobuk-team/intel-graphics
    sudo apt update
  else
    log_ok "[INTEL] PPA kobuk-team/intel-graphics ya presente."
  fi
  for pkg in "${INTEL_PKGS[@]}"; do
    INSTALLED_VER=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
    CANDIDATE_VER=$(apt-cache policy "$pkg" 2>/dev/null | grep Candidate | awk '{print $2}')
    if [ -n "$INSTALLED_VER" ]; then
      if [ -n "$CANDIDATE_VER" ] && dpkg --compare-versions "$CANDIDATE_VER" gt "$INSTALLED_VER"; then
        log_warn "[$pkg] Instalado ($INSTALLED_VER), pero hay versión más reciente ($CANDIDATE_VER). Actualizando..."
        sudo apt-get install -y "$pkg" && log_ok "[$pkg] actualizado a $CANDIDATE_VER."
      else
        log_ok "[$pkg] ya instalado en versión $INSTALLED_VER."
      fi
    else
      log_warn "[$pkg] Instalando..."
      sudo apt-get install -y "$pkg" && log_ok "[$pkg] instalado OK." || { log_err "[$pkg] ERROR al instalar."; SUCCESS=false; }
    fi
  done
fi

####################################################################################
# [8] INSTALACIÓN DE UTILIDADES ADICIONALES DE GPU / DESARROLLO                    #
# - Instala utilidades recomendadas para monitoreo y desarrollo de GPU.
# - Actualiza si hay versiones más recientes.
####################################################################################
log_mod "[INSTALACIÓN DE PAQUETES Y UTILIDADES]"
for pkg in "${UTILS_PKGS[@]}"; do
  INSTALLED_VER=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
  CANDIDATE_VER=$(apt-cache policy "$pkg" 2>/dev/null | grep Candidate | awk '{print $2}')
  if [ -n "$INSTALLED_VER" ]; then
    if [ -n "$CANDIDATE_VER" ] && dpkg --compare-versions "$CANDIDATE_VER" gt "$INSTALLED_VER"; then
      log_warn "[$pkg] Instalado ($INSTALLED_VER), pero hay versión más reciente ($CANDIDATE_VER). Actualizando..."
      sudo apt-get install -y "$pkg" && log_ok "[$pkg] actualizado a $CANDIDATE_VER."
    else
      log_ok "[$pkg] ya instalado en versión $INSTALLED_VER."
    fi
  else
    log_warn "[$pkg] Instalando..."
    sudo apt-get install -y "$pkg" && log_ok "[$pkg] instalado OK." || { log_err "[$pkg] ERROR al instalar."; SUCCESS=false; }
  fi
done

####################################################################################
# [9] VERIFICACIÓN E INSTALACIÓN DE NASM                                            #
# - Verifica si NASM está instalado y en versión adecuada.
# - Instala o actualiza NASM si es necesario, evitando fallos de compilación FFmpeg.
####################################################################################
log_mod "[VERIFICACIÓN DE NASM]"
if ! command -v nasm &>/dev/null; then
  log_warn "[NASM] NASM no encontrado. Instalando..."
  sudo apt-get install -y nasm
elif ! nasm -v | grep -E 'version (2\.1[3-9]|2\.[2-9][0-9]|[3-9]\.)' &>/dev/null; then
  log_warn "[NASM] Versión NASM muy antigua. Actualizando..."
  sudo apt-get install -y nasm
else
  log_ok "[NASM] NASM detectado y en versión adecuada."
fi

####################################################################################
# [10] COMPILACIÓN DE FFMPEG CON SOPORTE GPU                                        #
# - Compila FFmpeg desde código fuente con los flags necesarios según hardware detectado.
# - Instala headers extra para NVIDIA si corresponde.
# - Elimina instalaciones previas para evitar conflictos.
# - Muestra logs detallados y verifica éxito en cada paso.
####################################################################################
log_mod "[DETECCIÓN Y COMPILACIÓN FFmpeg]"
FFMPEG_FLAGS="--enable-gpl --enable-nonfree --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus \
--enable-libfdk_aac --enable-libass --enable-libfreetype --enable-libvorbis --enable-libmp3lame --enable-libaom $SVTAV1_FLAG \
--enable-libsoxr --enable-libspeex --enable-libwebp --enable-libopenjpeg"

if $HAS_NVIDIA; then
  cd /root
  if [ ! -d nv-codec-headers ]; then
    git clone https://github.com/FFmpeg/nv-codec-headers.git
    cd nv-codec-headers
    make && sudo make install
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
    cd /root
  fi
  FFMPEG_FLAGS="$FFMPEG_FLAGS --enable-cuda-nvcc --enable-nvenc --enable-cuvid --enable-libnpp --extra-cflags=-I/usr/local/include/ffnvcodec --extra-ldflags=-L/usr/local/include/ffnvcodec"
fi

if $HAS_INTEL; then
  FFMPEG_FLAGS="$FFMPEG_FLAGS --enable-libmfx --enable-vaapi"
fi

HAS_NVENC=$(ffmpeg -encoders 2>/dev/null | grep -w h264_nvenc)
HAS_QSV=$(ffmpeg -encoders 2>/dev/null | grep -w h264_qsv)
HAS_VAAPI=$(ffmpeg -encoders 2>/dev/null | grep -w h264_vaapi)
NEED_REBUILD=false

if $HAS_NVIDIA && $HAS_INTEL; then
  if [[ -z "$HAS_NVENC" || (-z "$HAS_QSV" && -z "$HAS_VAAPI") ]]; then
    NEED_REBUILD=true
  fi
elif $HAS_NVIDIA && [[ -z "$HAS_NVENC" ]]; then
  NEED_REBUILD=true
elif $HAS_INTEL && [[ -z "$HAS_QSV" && -z "$HAS_VAAPI" ]]; then
  NEED_REBUILD=true
fi

if ! command -v ffmpeg &>/dev/null || $NEED_REBUILD; then
  log_warn "[FFMPEG] Recompilando FFmpeg para incluir soporte para todos los GPUs detectados..."
  sudo apt-get remove --purge -y ffmpeg
  sudo apt-get autoremove -y
  sudo rm -rf /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/bin/ffmpeg /usr/bin/ffprobe
  sudo rm -rf /usr/local/lib/libav* /usr/lib/libav* /usr/local/include/libav* /usr/include/libav*
  hash -r

  cd /root
  rm -rf FFmpeg
  git clone https://github.com/FFmpeg/FFmpeg.git
  cd FFmpeg

  log_warn "[FFMPEG] Configurando con flags: $FFMPEG_FLAGS"
  ./configure $FFMPEG_FLAGS | tee /root/ffmpeg_compile_detail.log
  CONFIG_OK=$?
  if [ $CONFIG_OK -ne 0 ]; then
    log_err "[FFMPEG] ERROR en la configuración. Revisa /root/ffmpeg_compile_detail.log para detalles."
    tail -20 /root/ffmpeg_compile_detail.log
    SUCCESS=false
  else
    log_warn "[FFMPEG] Compilando..."
    make -j$(nproc) | tee -a /root/ffmpeg_compile_detail.log
    sudo make install | tee -a /root/ffmpeg_compile_detail.log
  fi
else
  log_ok "[FFMPEG] FFmpeg ya tiene soporte para todos los GPUs presentes, NO se recompila."
fi

####################################################################################
# [11] PRUEBAS DE ACELERACIÓN HW (VERIFICACIÓN FFmpeg GPU)                         #
# - Ejecuta pruebas automáticas de transcodificación y decodificación FFmpeg según los encoders HW detectados.
# - Guarda los resultados en logs separados para fácil diagnóstico.
####################################################################################
log_mod "[PRUEBAS DE ACELERACION HW]"
if $SUCCESS; then
  log_ok "[FFMPEG] Verificando aceleración HW disponible..."
  ffmpeg -encoders | grep -E "nvenc|qsv|vaapi|vdpau" | tee /root/ffmpeg_hw_check.log
  ffmpeg -decoders | grep -E "nvdec|qsv|vaapi|vdpau" | tee -a /root/ffmpeg_hw_check.log
  ffmpeg -hwaccels | tee -a /root/ffmpeg_hw_check.log
  log_ok "[FFMPEG] Generando video de prueba para test HW..."
  ffmpeg -f lavfi -i testsrc=duration=5:size=1280x720:rate=30 -c:v libx264 -pix_fmt yuv420p /root/test_input.mp4
  log_ok "[FFMPEG] Probando transcodificación con aceleración HW..."
  if ffmpeg -encoders | grep -q h264_nvenc; then
    ffmpeg -y -hwaccel cuda -i /root/test_input.mp4 -c:v h264_nvenc /root/test_output_nvenc.mp4 | tee /root/ffmpeg_hw_test.log
  elif ffmpeg -encoders | grep -q h264_qsv; then
    ffmpeg -y -hwaccel qsv -i /root/test_input.mp4 -c:v h264_qsv /root/test_output_qsv.mp4 | tee /root/ffmpeg_hw_test.log
  elif ffmpeg -encoders | grep -q h264_vaapi; then
    ffmpeg -y -hwaccel vaapi -i /root/test_input.mp4 -c:v h264_vaapi /root/test_output_vaapi.mp4 | tee /root/ffmpeg_hw_test.log
  elif ffmpeg -encoders | grep -q h264_vdpau; then
    ffmpeg -y -hwaccel vdpau -i /root/test_input.mp4 -c:v h264_vdpau /root/test_output_vdpau.mp4 | tee /root/ffmpeg_hw_test.log
  else
    log_warn "[FFMPEG][WARNING] No se detectó encoder HW soportado para prueba automática."
  fi
fi

####################################################################################
# [12] PARCHEO NVIDIA-PATCH (ELIMINA LIMITES NVENC/NVIDIA)                         #
# - Descarga y aplica el parche nvidia-patch si el driver NVIDIA esperado está activo y el sistema fue recién reiniciado.
# - Elimina límites NVENC para streams concurrentes.
####################################################################################
log_mod "[PARCHEANDO DRIVER NVIDIA (nvidia-patch)]"
if $HAS_NVIDIA; then
  NVIDIA_INSTALLED=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
  if [[ "$NVIDIA_INSTALLED" == "$NVIDIA_EXPECTED" ]]; then
    if [ -f "$REBOOT_FLAG" ]; then
      cd /root
      if [ -d nvidia-patch ]; then
        log_warn "Directorio nvidia-patch ya existe, eliminando para clonar limpio..."
        sudo rm -rf /root/nvidia-patch
      fi
      git clone https://github.com/keylase/nvidia-patch && log_ok "Repositorio nvidia-patch clonado."
      cd nvidia-patch
      ./patch.sh && log_ok "nvidia-patch.sh aplicado correctamente." || log_err "Error al aplicar patch.sh."
      ./patch-fbc.sh && log_ok "nvidia-patch-fbc.sh aplicado correctamente." || log_err "Error al aplicar patch-fbc.sh."
      cd /root
      rm -f "$REBOOT_FLAG"
    else
      log_warn "[nvidia-patch] Parcheo saltado: aún no hay reinicio tras instalar driver NVIDIA. Corre el script de nuevo tras reiniciar."
    fi
  else
    log_warn "[nvidia-patch] Parcheo saltado: el driver NVIDIA $NVIDIA_EXPECTED no está instalado aún."
  fi
fi

####################################################################################
# [13] PROTECCIÓN CONTRA ACTUALIZACIÓN (APT HOLD) Y DESACTIVACIÓN DE AUTO-UPGRADE  #
# - Protege paquetes críticos del kernel y drivers NVIDIA contra actualizaciones automáticas.
# - Desinstala unattended-upgrades para evitar roturas del entorno por actualizaciones imprevistas.
####################################################################################
log_mod "[PROTEGIENDO DRIVERS/KERNEL CONTRA ACTUALIZACION Y DESACTIVANDO UNATTENDED-UPGRADES]"

if $HAS_NVIDIA; then
  for pkg in $(dpkg -l | grep nvidia | awk '{print $2}'); do
    sudo apt-mark hold "$pkg" && log_ok "Hold aplicado a paquete NVIDIA: $pkg"
  done
fi

sudo apt-mark hold "$KERNEL_PKG" && log_ok "Hold aplicado a kernel: $KERNEL_PKG"
sudo apt-mark hold "$KERNEL_HDR" && log_ok "Hold aplicado a headers: $KERNEL_HDR"

HOLDS=$(apt-mark showhold)
if ! echo "$HOLDS" | grep -q "$KERNEL_PKG"; then
  log_warn "CUIDADO: El kernel actual NO está en hold. Puede actualizarse y romper NVIDIA."
fi
if ! echo "$HOLDS" | grep -q "$KERNEL_HDR"; then
  log_warn "CUIDADO: Los headers actuales NO están en hold. Puede actualizarse y romper NVIDIA."
fi
if $HAS_NVIDIA; then
  for pkg in $(dpkg -l | grep nvidia | awk '{print $2}'); do
    if ! echo "$HOLDS" | grep -q "$pkg"; then
      log_warn "CUIDADO: El paquete NVIDIA $pkg NO está en hold."
    fi
  done
fi

if dpkg -l | grep -q unattended-upgrades; then
  log_warn "ATENCIÓN: El paquete unattended-upgrades está instalado. Procediendo a desinstalarlo para evitar actualizaciones automáticas."
  sudo apt-get remove --purge -y unattended-upgrades && log_ok "unattended-upgrades desinstalado correctamente."
else
  log_ok "unattended-upgrades NO está instalado."
fi

if $HAS_NVIDIA && ! nvidia-smi &>/dev/null; then
  log_err "ERROR: El driver NVIDIA no está funcional. Reinstala el driver tras actualizar kernel."
fi

####################################################################################
# [14] RESUMEN FINAL Y LIMPIEZA                                                    #
# - Muestra resumen del proceso, resultados y recomendaciones finales.
# - Limpia flags temporales.
####################################################################################
log_mod "[RESUMEN FINAL]"
if $SUCCESS; then
  echo -e "${GREEN}✅ Todo el proceso fue exitoso. Drivers, dependencias, utilidades y FFmpeg instalados y verificados. Pruebas de aceleración completadas.${NC}"
  echo -e "${BLUE}Consulta el log completo en $LOG_FILE y los resultados de aceleración en /root/ffmpeg_hw_check.log y /root/ffmpeg_hw_test.log${NC}"
  if [ -z "$SVTAV1_FLAG" ]; then
    echo -e "${YELLOW}⚠ SVT-AV1 no fue detectado, FFmpeg NO soportará AV1 hardware (Intel/AMD).${NC}"
  fi
  if [ ${#OPCIONAL_FALTANTES[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠ Paquetes opcionales omitidos:${NC}"
    for pkg in "${OPCIONAL_FALTANTES[@]}"; do
      echo -e "${YELLOW} - $pkg${NC}"
    done
    echo -e "${YELLOW}Puedes instalarlos manualmente si los necesitas para funciones extra de FFmpeg.${NC}"
  fi
else
  echo -e "${RED}❌ Proceso terminado con errores críticos. Revisa los logs en $LOG_FILE para detalles y corrige los problemas reportados.${NC}"
  if [ -z "$SVTAV1_FLAG" ]; then
    echo -e "${YELLOW}⚠ SVT-AV1 no fue detectado, FFmpeg NO soportará AV1 hardware (Intel/AMD).${NC}"
  fi
  if [ ${#OPCIONAL_FALTANTES[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠ Paquetes opcionales omitidos:${NC}"
    for pkg in "${OPCIONAL_FALTANTES[@]}"; do
      echo -e "${YELLOW} - $pkg${NC}"
    done
    echo -e "${YELLOW}Puedes instalarlos manualmente si los necesitas para funciones extra de FFmpeg.${NC}"
  fi
fi

if [ -f "$REBOOT_FLAG" ]; then
  rm -f "$REBOOT_FLAG"
fi

####################################################################################
# [15] CLONAR REPOSITORIO udp_push CANALES UDP POR SSH Y DAR PERMISOS              #
# - Clona el repositorio canales_udp por SSH para evitar pedir usuario/contraseña.
# - Verifica existencia de clave SSH y aborta con instrucciones si no está.
# - Otorga permisos 777 a la carpeta y su contenido.
####################################################################################
UDP_DIR="/home/udp_push"
UDP_REPO="git@github.com:chuymex/canales_udp.git"

log_mod "[CLONANDO REPOSITORIO CANALES UDP POR SSH SI NO EXISTE]"

if [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
  log_warn "No se encontró clave SSH en $HOME/.ssh/. Para evitar pedir user/pass, genera una con:"
  echo "ssh-keygen -t ed25519 -C \"$(whoami)@$(hostname)\""
  echo "Luego agrega la clave pública (~/.ssh/id_ed25519.pub) a tu cuenta de GitHub."
  log_warn "Clonación abortada. Ejecuta el comando anterior y vuelve a correr el script."
else
  if [ ! -d "$UDP_DIR" ]; then
    log_ok "Creando carpeta $UDP_DIR y clonando repositorio por SSH..."
    mkdir -p "$UDP_DIR"
    git clone "$UDP_REPO" "$UDP_DIR"
    chmod -R 777 "$UDP_DIR"
    log_ok "Permisos 777 otorgados a $UDP_DIR y todo su contenido."
  else
    log_info "Carpeta $UDP_DIR ya existe. No se realiza clonación ni cambio de permisos."
  fi
fi

####################################################################################
# [16] CREACIÓN DE SERVICIO SYSTEMD PARA CANALES UDP                               #
# - Crea el servicio systemd canales_udp si no existe o no apunta al script correcto.
# - Permite ejecución automática de canales_udp.sh como root tras reinicio.
####################################################################################
SERVICE_NAME="canales_udp"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_PATH="/home/udp_push/canales_udp.sh"

log_mod "[CREANDO SERVICIO SYSTEMD PARA CANALES UDP SI NO EXISTE]"

if [ ! -f "$SCRIPT_PATH" ]; then
  log_warn "El archivo $SCRIPT_PATH no existe, no se puede crear el servicio systemd."
else
  if [ -f "$SERVICE_PATH" ] && grep -q "$SCRIPT_PATH" "$SERVICE_PATH"; then
    log_info "El servicio $SERVICE_NAME ya existe y apunta a $SCRIPT_PATH. No se realiza ninguna acción."
  else
    log_ok "Creando servicio systemd $SERVICE_NAME para $SCRIPT_PATH"
    cat <<EOF | sudo tee "$SERVICE_PATH"
[Unit]
Description=Servicio Canales UDP
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 644 "$SERVICE_PATH"
    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME"
    log_ok "Servicio $SERVICE_NAME creado, habilitado y arrancado correctamente."
  fi
fi

####################################################################################
# [FIN DEL SCRIPT]                                                                 #
# - Finaliza el proceso y deja el entorno listo para producción.
####################################################################################
