OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    DDR3 (rwx) : ORIGIN = 0x80000000, LENGTH = 512K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        __text_start = .;
        *(.text.init)
        *(.text*)
        __text_end = .;
    } > DDR3

    .rodata : ALIGN(4)
    {
        __rodata_start = .;
        *(.rodata*)
        __rodata_end = .;
    } > DDR3

    .data : ALIGN(4)
    {
        __data_start = .;
        *(.data*)
        *(.sdata*)
        __data_end = .;
    } > DDR3

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.sbss*)
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > DDR3

    _end = .;
    PROVIDE(end = .);
    __stack_top = ORIGIN(DDR3) + LENGTH(DDR3);
    PROVIDE(_stack = __stack_top);
}
