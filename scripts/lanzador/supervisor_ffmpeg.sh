#!/bin/bash

# Script para supervisar procesos ffmpeg por canal

# Función para iniciar el proceso ffmpeg
start_ffmpeg() {
    # Lógica para iniciar el proceso ffmpeg
    ffmpeg -i canal_input -c:v libx264 -c:a aac canal_output
}

# Función para supervisar el proceso
supervise_ffmpeg() {
    while true; do
        start_ffmpeg
        echo "Proceso ffmpeg cerrado. Reiniciando..."
        sleep 2 # Esperar antes de reiniciar
    done
}

# Iniciar la supervisión
supervise_ffmpeg
