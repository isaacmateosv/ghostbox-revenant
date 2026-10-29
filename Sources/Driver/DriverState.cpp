#include "DriverState.h"

namespace mbox {

DriverState gState;

os_log_t driverLog() {
    static os_log_t instance = os_log_create(GHOSTBOX_DRIVER_ID, "driver");
    return instance;
}

}  // namespace mbox
