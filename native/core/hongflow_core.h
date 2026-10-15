#ifndef HONGFLOW_CORE_H
#define HONGFLOW_CORE_H
#ifdef __cplusplus
extern "C" {
#endif
// All returned strings are allocated by the core and must be released with HongFlowFree.
char *HongFlowVersion(void);
char *HongFlowValidate(const char *yaml);
char *HongFlowStart(const char *configPath, const char *homeDir, int tunFd, const char *controllerSecret);
char *HongFlowStop(void);
char *HongFlowSetMode(const char *mode, const char *controllerSecret);
void HongFlowFree(void *pointer);
#ifdef __cplusplus
}
#endif
#endif
