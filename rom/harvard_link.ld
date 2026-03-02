OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x00000000;
    .text : ALIGN(4)
    {
        *(.text*)
        *(.rodata*)
    }

    . = 0x00001000;
    .data : ALIGN(4)
    {
        *(.data*)
        *(.sdata*)
    }

    .bss (NOLOAD) : ALIGN(4)
    {
        *(.sbss*)
        *(.bss*)
        *(COMMON)
    }
}
