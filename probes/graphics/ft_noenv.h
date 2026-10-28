/* Keep upstream options, except runtime environment-variable configuration. */
#include <freetype/config/ftoption.h>
#undef FT_CONFIG_OPTION_ENVIRONMENT_PROPERTIES
#ifdef PROBE_FT_RENDER_POOL_BYTES
#undef FT_RENDER_POOL_SIZE
#define FT_RENDER_POOL_SIZE PROBE_FT_RENDER_POOL_BYTES
#endif
