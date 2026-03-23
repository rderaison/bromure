export LANG=%%LOCALE%%.UTF-8
export LC_ALL=%%LOCALE%%.UTF-8
export LD_PRELOAD=/usr/lib/libresolv_stub.so

# Match macOS Core Text stroke weight — FreeType renders thinner by default.
export FREETYPE_PROPERTIES="cff:no-stem-darkening=0 autofitter:no-stem-darkening=0"
