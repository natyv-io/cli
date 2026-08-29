// Compiles stb_image (decode) + stb_image_resize2 (resize) + stb_image_write
// (PNG re-encode) as real C, linked only into the `natyv` CLI itself, never
// natyv-core -- used solely by Windows icon generation (see
// src/cli/WindowsIcon.zig) to turn the dev's one source PNG (`Config.icon`)
// into the several resized PNGs a real `.ico` container embeds. A separate
// translation unit from vendor/stb/stb_image_impl.c (natyv-core's own
// runtime texture-fill decoder, a different binary entirely -- no link
// collision, no need to share flags): `STBI_NO_STDIO` doesn't apply here
// since this is offline build tooling, not code running inside natyv-core's
// closed runtime input surface.
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
