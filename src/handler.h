#pragma once

typedef int (*Luau_AssertHandler)(const char* expression, const char* file, int line, const char* function);

#ifdef __cplusplus
extern "C" {
#endif

void luau_set_assert_handler(Luau_AssertHandler handler);

#ifdef __cplusplus
}
#endif