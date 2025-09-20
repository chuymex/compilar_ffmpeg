# Script Master FFmpeg + GPU Drivers + Utilidades + Pruebas + Protección Actualizaciones

## Descripción General

Este script automatiza la instalación y configuración avanzada de FFmpeg con soporte para aceleración por GPU (NVIDIA e Intel), incluye la gestión segura de drivers, utilidades, pruebas de aceleración, protección contra actualizaciones automáticas y el despliegue de servicios systemd para scripts personalizados.

Está modularizado y comentado para facilitar su extensión y mantenimiento.

---

## Requisitos previos

- **Ubuntu/Debian recomendado**
- Usuario con permisos sudo
- Acceso a internet
- (Opcional) Clave SSH generada y agregada a tu cuenta GitHub para clonar repos privados

---

## ¿Qué hace este script?

1. **Desinstala y bloquea el driver abierto Nouveau** si está presente (requiere reinicio).
2. **Instala todas las dependencias críticas y opcionales** para FFmpeg y drivers GPU.
3. **Instala/configura drivers NVIDIA o Intel** según el hardware detectado.
4. **Compila FFmpeg desde cero** con todos los módulos y soporte HW detectados.
5. **Verifica aceleración HW disponible** en FFmpeg con pruebas automáticas.
6. **Aplica parche nvidia-patch** para eliminar límites de NVENC en NVIDIA.
7. **Protege drivers y kernel contra actualizaciones automáticas** con apt-mark hold y desinstala unattended-upgrades.
8. **Clona tu repositorio privado UDP por SSH**, generando la clave SSH si no existe.
9. **Despliega servicio systemd** para ejecutar automáticamente tu script canales_udp.sh.
10. **Provee logs detallados** de cada paso para diagnóstico y auditoría.

---

## Cómo ejecutar el script

### 1. Descarga el script

Guarda el archivo como `ffmpeg_gpu_master.sh`:

```bash
curl -O https://raw.githubusercontent.com/chuymex/scripts/master/ffmpeg_gpu_master.sh
chmod +x ffmpeg_gpu_master.sh
```

(Ejemplo, sustituye la URL por tu fuente real si es necesario).

---

### 2. Ejecuta como root o con sudo

```bash
sudo ./ffmpeg_gpu_master.sh
```

---

### 3. Clave SSH para GitHub (solo la primera vez)

- Si no tienes clave SSH, el script la generará automáticamente y **te la mostrará en el log**.
- **Copia la clave pública** que aparece en el log y pégala en [GitHub > Settings > SSH and GPG keys](https://github.com/settings/keys).

```text
Agrega la siguiente clave pública a tu cuenta de GitHub:
---------------------------------------------
ssh-ed25519 AAAAC3... chuymex@outlook.com
---------------------------------------------
```
- Una vez agregada, **vuelve a ejecutar el script**.

---

### 4. Logs y diagnóstico

- El log principal está en: `/root/resultado_instalacion.txt`
- Resultados de aceleración HW en: `/root/ffmpeg_hw_check.log` y `/root/ffmpeg_hw_test.log`

---

### 5. Servicio systemd

El servicio `canales_udp` se crea y se inicia automáticamente, ejecutando `/home/udp_push/canales_udp.sh`.

Puedes administrar el servicio con:

```bash
sudo systemctl status canales_udp
sudo systemctl restart canales_udp
sudo systemctl stop canales_udp
```

---

## Personalización

- **Drivers NVIDIA:** Edita la variable `NVIDIA_EXPECTED` para cambiar la versión.
- **Soporte AV1:** El script detecta automáticamente si SVT-AV1 está disponible.
- **Dependencias:** Agrega/quita paquetes en los arrays `DEPENDENCIES`, `CRITICOS`, `OPCIONALES`, `INTEL_PKGS`, `UTILS_PKGS`.
- **Repositorio UDP:** Cambia la variable `UDP_REPO` si tu repo UDP cambia de nombre o ubicación.

---

## Seguridad y buenas prácticas

- **La clave privada SSH nunca se muestra ni comparte.**
- **La clave SSH generada solo sirve para este servidor y tu cuenta GitHub.**
- **El script detiene su ejecución si la clave SSH es nueva, para que agregues la pública antes de continuar.**
- **Revisa el log para cualquier error crítico antes de reiniciar o continuar.**

---

## Soporte y dudas

¿Tienes dudas o necesitas adaptar el script para otro hardware, versión de FFmpeg o integración?  
Abre un issue en tu repo de scripts, ¡o contáctame directamente!

---

## Créditos

Script y documentación por **chuymex**.
