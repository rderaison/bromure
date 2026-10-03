# One Linux VM, several macOS windows

Verified on the current macOS 27 / Xcode 27.1 host on 2026-10-02:

- A VM configured with two independent `VZCustomVirtioDeviceConfiguration`
  GPU devices validates and boots.
- Linux's stock `virtio_gpu` module negotiates DRIVER_OK on both devices.
  The guest creates DRM card0 and card1, each with a Virtual connector.
- Apple's built-in `VZVirtioGraphicsDeviceConfiguration` with two scanouts
  fails validation: `More than one scanout is configured.` The installed
  SDK header explicitly documents a maximum of one scanout.

This is a device/driver feasibility result. The probe intentionally advertises
no usable display or 3D capsets, and has no renderer or Chromium process. It
cannot establish accelerated multi-monitor rendering or working browser windows.
The guest disk is attached read-only, with no networking. The probe loads a
module and inspects sysfs; it does not modify the image.

Reproduce on macOS 27 with an existing image directory:

```sh
xcrun swiftc -target arm64-apple-macosx14.0 tools/gpu/validate-multiple-gpus.swift -o /tmp/bromure-multigpu-probe
codesign --force --sign - --entitlements tools/gpu/probe.entitlements /tmp/bromure-multigpu-probe
/tmp/bromure-multigpu-probe '/path/to/image directory'
```

Evidence: [multi-gpu-probe.log](multi-gpu-probe.log). The read-only image may
report skipped orphan cleanup; this probe does not test filesystem health.

## Experimental implementation

The `multi-gpu-browser` command now attaches two custom Virtio GPU devices,
each with its own renderer worker and resource namespace, to one VM. One Xorg
server runs two independent X screens with explicit PCI device selection and
Xinerama disabled. Each macOS window observes and resizes its own GPU session.
The production browser entry point continues to use one GPU.

Each screen starts a separate Chromium process and ephemeral browser profile.
Cookies are separate, but both browsers share the Linux VM, filesystem, network,
D-Bus session and audio. This does not provide separate-VM security isolation.
Closing one macOS window detaches its view; closing the last stops the shared VM.

Activation requires macOS 27 and a private guest image containing the
experimental guest scripts. The boot argument `bromure.experimental_multigpu=2`
selects the guest path. Input uses a shared host-only vsock port 5830 with an
explicit screen number; the existing production pointer protocol is unchanged.
Clicks focus the selected X screen, and keyboard events use the shared VZ input
path. Experimental scrolling currently uses accumulated X wheel button events.

Actual hardware testing confirms both GPUs render frames and both Chromium
processes report VirGL on their distinct render nodes. Input, presentation,
resize and close acceptance is still in progress. The initial Xorg startup
failure was its privileged absolute `-config` path; root preparation now writes
an `/etc/X11` configuration selected by relative name.

Example (using the experimental preview executable):

```sh
bromure multi-gpu-browser --storage-dir /path/to/private-image --seconds 0
```

Native Chromium controls are shown in each window. This experiment does not yet
integrate the normal native tab/profile editor or dynamic GPU hot-plug.

Apple references:
[customVirtioDevices](https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/customvirtiodevices)
and [scanout configuration](https://developer.apple.com/documentation/virtualization/vzvirtiographicsscanoutconfiguration).
The array-shaped API alone does not establish supported scanout count; the live
validation result and SDK restriction are decisive here.
