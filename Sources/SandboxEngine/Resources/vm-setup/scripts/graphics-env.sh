#!/bin/sh
# Sourced by xinitrc after chrome-env. Keep this independent of X startup so
# diagnostics and tests use exactly the same Mesa environment as Chromium.
# GRAPHICS_BACKEND is a host-selected configuration, not a hardware probe.
case "${GRAPHICS_BACKEND:-software}" in
    virgl)
        # A stale inherited software override must not mask the selected GPU.
        unset LIBGL_ALWAYS_SOFTWARE
        if [ -f /opt/bromure/mesa-virgl/graphics-build.txt ]; then
            LIBGL_DRIVERS_PATH=/opt/bromure/mesa-virgl/lib/dri
            LIBVA_DRIVERS_PATH=$LIBGL_DRIVERS_PATH
            LIBVA_DRIVER_NAME=virtio_gpu
            # Chromium-only libva RGB facade; its dependency is real libva.
            LD_LIBRARY_PATH=/opt/bromure/chromium-vaapi:/opt/bromure/mesa-virgl/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            export LIBGL_DRIVERS_PATH LIBVA_DRIVERS_PATH LIBVA_DRIVER_NAME LD_LIBRARY_PATH
        fi
        ;;
    *)
        GRAPHICS_BACKEND=software
        # Preserve the legacy developer escape hatch for A/B experiments.
        [ "${NO_LIBGL_SOFTWARE:-0}" = "1" ] || LIBGL_ALWAYS_SOFTWARE=1
        ;;
esac
export GRAPHICS_BACKEND
if [ "${LIBGL_ALWAYS_SOFTWARE+x}" = x ]; then
    export LIBGL_ALWAYS_SOFTWARE
fi
