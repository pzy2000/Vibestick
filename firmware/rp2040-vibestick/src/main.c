#include "bsp/board_api.h"
#include "tusb.h"

int main(void)
{
    board_init();
    tusb_init();

    while (true)
    {
        tud_task();
    }
}

void tud_mount_cb(void)
{
}

void tud_umount_cb(void)
{
}

void tud_suspend_cb(bool remote_wakeup_en)
{
    (void)remote_wakeup_en;
}

void tud_resume_cb(void)
{
}
