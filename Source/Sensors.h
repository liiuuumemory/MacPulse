#include <stdint.h>
#include <stddef.h>
uint32_t mp_smc_open(void);
void mp_smc_close(uint32_t connection);
int mp_smc_read(uint32_t connection, const char *key, double *value);
int mp_smc_info(uint32_t connection, const char *key, uint32_t *type, uint32_t *size);
int mp_smc_read_info(uint32_t connection, const char *key, uint32_t type, uint32_t size, double *value);
int mp_smc_key(uint32_t connection, uint32_t index, char *key);
int mp_network_counters(const char *name, uint64_t *received, uint64_t *sent);
long mp_netstat(char *buffer, size_t capacity);
int mp_power_open(void);
int mp_power_sample(double *cpu, double *gpu, double *ane);
void mp_power_close(void);
