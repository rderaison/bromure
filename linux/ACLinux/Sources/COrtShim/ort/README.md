# onnxruntime C API headers (vendored)

`onnxruntime_c_api.h` and `onnxruntime_ep_c_api.h` from onnxruntime 1.23.2
(MIT, `LICENSE`), as the official release ships them: taken from
`onnxruntime-linux-x64-1.23.2.tgz` and byte-identical to
`include/onnxruntime/core/session/onnxruntime_c_api.h` at tag v1.23.2.
The shim (`../acl_ort.c`) is built against them and asks for API version
`ORT_API_VERSION` (23); nothing links against libonnxruntime.

At run time the library comes from the distro (`libonnxruntime1.23`,
1.23.2, apt-signed) by default, or `BROMURE_ONNXRUNTIME=<path to .so>`.
The documented fallback is the official tarball, checked against:

| file | sha256 |
|---|---|
| onnxruntime-linux-x64-1.23.2.tgz | 1fa4dcaef22f6f7d5cd81b28c2800414350c10116f5fdd46a2160082551c5f9b |
| onnxruntime-linux-aarch64-1.23.2.tgz | 7c63c73560ed76b1fac6cff8204ffe34fe180e70d6582b5332ec094810241e5c |
| include/onnxruntime_c_api.h | 71125e66180a991d65c9bdbad4aa20daaa1f7a48c7a5c0fa5f18f250ac839a02 |
| include/onnxruntime_ep_c_api.h | b92778f50c36ecdf53d0344e0129a78b306afed653f81bba8a9597e3e6e9546f |

(The tarball digests are GitHub's published asset digests for release
v1.23.2, re-checked on download.)
