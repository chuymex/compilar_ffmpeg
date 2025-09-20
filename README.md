# Script Master FFmpeg + GPU Drivers + Utilidades + Pruebas + Protección Actualizaciones

## Descripción General

Este script automatiza la **instalación, verificación y protección completa del entorno multimedia y de cómputo acelerado por GPU** en sistemas Linux (especialmente Ubuntu/Debian), integrando:

- Compilación personalizada de **FFmpeg** con soporte avanzado para NVIDIA e Intel (y AV1 si está disponible).
- Instalación, verificación y protección de drivers de GPU.
- Instalación y actualización de dependencias críticas y opcionales.
- Pruebas automáticas para asegurarse de que la aceleración hardware esté disponible y funcional.
- Parcheo de limitaciones de NVENC/NVIDIA (parche `nvidia-patch`).
- Protección contra actualizaciones automáticas inesperadas (kernel, drivers, unattended-upgrades).
- Instalación de utilidades de desarrollo y monitoreo de GPU.
- Clonación y configuración de un repositorio propio de canales UDP, con servicio systemd para ejecución automática.

---

## Funcionalidades Detalladas

### 1. Desinstalación de Nouveau
- Detecta si el driver abierto Nouveau (NVIDIA) está activo.
- Si lo está, lo desinstala y bloquea su carga.
- Aplica los cambios y fuerza un reinicio para evitar conflictos con el driver propietario NVIDIA.

### 2. Liberación de Paquetes en Hold
- Remueve cualquier bloqueo (hold) de drivers NVIDIA y kernel para permitir su actualización e instalación.

### 3. Detección Automática de GPU
- Detecta la presencia de GPU NVIDIA e Intel para instalar únicamente los componentes necesarios.

### 4. Instalación y Actualización de Dependencias
- Instala todas las dependencias necesarias para FFmpeg y procesamiento multimedia por hardware.
- Actualiza paquetes si existe una versión más reciente.
- Informa sobre los paquetes opcionales no encontrados.

### 5. Verificación y Configuración de SVT-AV1
- Verifica si el soporte AV1 hardware via SVT-AV1 está disponible.
- Si no está, compila FFmpeg sin dicho soporte para evitar errores.

### 6. Instalación y Verificación de Drivers GPU
- Instala y verifica drivers propietarios NVIDIA e Intel.
- Descarga automáticamente la versión especificada de NVIDIA.
- Añade PPA oficial de Intel si es necesario.
- Fuerza reinicio tras cambios críticos.

### 7. Instalación de Utilidades de GPU/Desarrollo
- Instala herramientas recomendadas para desarrollo y monitoreo de GPU (ej. `nvtop`, `intel-gpu-tools`, `nvidia-cuda-toolkit`).

### 8. Verificación e Instalación de NASM
- Instala o actualiza NASM para compilar FFmpeg con optimizaciones x86.

### 9. Compilación Personalizada de FFmpeg
- Descarga y compila FFmpeg desde código fuente con flags avanzados según hardware detectado.
- Elimina instalaciones previas para evitar conflictos.
- Integra headers extra para soporte NVIDIA.
- Muestra logs detallados y verifica el éxito de cada paso.

### 10. Pruebas Automáticas de Aceleración Hardware
- Ejecuta pruebas automáticas de transcodificación y decodificación.
- Verifica que los encoders/decoders hardware estén presentes y funcionales.
- Guarda resultados en logs separados para diagnóstico.

### 11. Parcheo de Límites NVENC/NVIDIA
- Descarga y aplica el parche `nvidia-patch` si el driver NVIDIA está activo.
- Elimina límites de streams concurrentes en NVENC.

### 12. Protección Contra Actualizaciones Automáticas
- Protege drivers y kernel críticos usando `apt-mark hold`.
- Desinstala `unattended-upgrades` para evitar actualizaciones automáticas.

### 13. Clonación y Configuración de Repositorio UDP
- Clona el repositorio **canales_udp** por SSH (sin pedir usuario/contraseña).
- Verifica la existencia de clave SSH y da instrucciones si no existe.
- Otorga permisos 777 a la carpeta y su contenido para máxima compatibilidad.

### 14. Creación de Servicio Systemd
- Crea un servicio systemd para ejecutar automáticamente `canales_udp.sh` tras reinicio.
- Verifica existencia y consistencia del servicio antes de crear o modificar.

### 15. Resumen Final y Limpieza
- Muestra un resumen de la instalación, pruebas e incidencias.
- Limpia flags temporales y deja el sistema listo para uso productivo.

---

## Requisitos Previos

- **Distribución Linux** basada en Debian/Ubuntu.
- Acceso `root` o permisos sudo.
- Conexión a internet para descargar repositorios y paquetes.
- Clave SSH configurada y agregada a tu cuenta de GitHub para clonar el repositorio privado por SSH.

## Ejecución

1. Copia el script en `/root` (o tu directorio de administración preferido).
2. Dale permisos de ejecución:
    ```bash
    chmod +x ffmpeg_gpu_master.sh
    ```
3. Ejecútalo como root:
    ```bash
    sudo ./ffmpeg_gpu_master.sh
    ```

## Notas Importantes

- Si el script detecta la ausencia de clave SSH, te indicará cómo crearla y agregarla a GitHub antes de clonar el repositorio canales_udp.
- Si el driver NVIDIA o kernel requiere reinicio, el script lo hará automáticamente y continuará tras el próximo arranque.
- Todos los pasos y resultados se registran en `/root/resultado_instalacion.txt` y otros logs específicos para facilitar diagnóstico.
- El script es modular y fácilmente extensible para agregar más utilidades o soporte para otras GPUs.

## Logs Generados

- **Log principal:** `/root/resultado_instalacion.txt`
- **Resultados pruebas GPU/FFmpeg:** `/root/ffmpeg_hw_check.log`, `/root/ffmpeg_hw_test.log`
- **Log de compilación FFmpeg:** `/root/ffmpeg_compile_detail.log`

---

## Contacto y Autor

- Script desarrollado por **chuymex**
- Puedes reportar incidencias o sugerencias en [GitHub](https://github.com/chuymex/canales_udp).

---

## Licencia

Este script se distribuye bajo licencia MIT. Úsalo y modifícalo libremente bajo tu propio riesgo.
