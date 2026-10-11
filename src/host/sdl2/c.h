/* SDL2 + SDL2_image + SDL2_mixer for zig/host/sdl2 (translated by build.zig). */
#define SDL_MAIN_HANDLED
#include <SDL.h>
#include <SDL_image.h>
#include <SDL_mixer.h>

/* Function-like / chained macros translate-c does not resolve. */
static const int sp_windowpos_centered = SDL_WINDOWPOS_CENTERED;
static const int sp_mix_max_volume = MIX_MAX_VOLUME;
static const Uint16 sp_audio_s16sys = AUDIO_S16SYS;
