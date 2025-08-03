#include "handler.h"
#include "Luau/Common.h"

void luau_set_assert_handler(Luau_AssertHandler handler) {
    Luau::assertHandler() = handler;
}