#import <Foundation/Foundation.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int mlx_ram_donor_is_available(void);
const char *mlx_ram_donor_last_error(void);
void mlx_ram_donor_set_kill_after_mapping(int enabled);
void *mlx_ram_donor_acquire_up_to(uint64_t requested, uint64_t minimum, uint64_t *granted);
void mlx_ram_donor_release(void *base);
void mlx_ram_donor_shutdown(void);

#ifdef __cplusplus
}
#endif
