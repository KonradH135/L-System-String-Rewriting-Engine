global _start

SYS_READ equ 0
SYS_WRITE equ 1
SYS_MMAP equ 9
SYS_MUNMAP equ 11
SYS_MREMAP equ 25
SYS_EXIT equ 60
STDIN equ 0
STDOUT equ 1
PROT_READ equ 0x1
PROT_WRITE equ 0x2
MAP_PRIVATE equ 0x02
MAP_ANONYMOUS equ 0x20
MREMAP_MAYMOVE equ 1
PAGE_SIZE equ 4096
NEW_LINE_CODE equ 10
MIN_ASCII equ 33
MAX_ASCII equ 126

section .bss
    rules: resq 256               ; table of pointers to replacement strings
    rules_len: resq 256           ; table of replacement string lengths
                                  ; (actually stores length + 1 to distinguish an empty string)

    input_buf: resq 1             ; input buffer
    input_buf_len: resq 1         ; size of the input buffer

    buf_a: resq 1                 ; current string buffer
    buf_b: resq 1                 ; next iteration string buffer
    buf_a_len: resq 1             ; size of buf_a
    buf_b_len: resq 1             ; size of buf_b

section .text

; rbx - remaining number of iterations to perform
; r12 - number of bytes read into input_buf
; r13 - number of occupied bytes in buf_a
; r14 - number of occupied bytes in buf_b

_start:

; ------------------------------------------
; |      Program argument handling         |
; ------------------------------------------

    mov rcx, [rsp]                ; load argument count (argc) into rcx
    cmp rcx, 2
    jne exit1                     ; if argc != 2, exit with error

    mov rcx, [rsp + 16]           ; load address of the first argument (iteration count)

    xor rbx, rbx                  

.parse_param:
    movzx rax, byte [rcx]         ; load next character
    test al, al                   ; check for null terminator (end of string)
    jz .end_parse_param

    cmp al, '0'                   ; verify that al contains a digit
    jb exit1
    cmp al, '9'
    ja exit1

    lea rbx, [rbx + rbx*4]        ; fast multiply rbx by 10
    shl rbx, 1

    sub al, '0'                   ; convert ASCII code to digit
    add rbx, rax                  ; add new digit to result

    inc rcx                       ; advance pointer to the next character
    jmp .parse_param

.end_parse_param:

    cmp rbx, 0                    ; if iteration count is not in range
    jb exit1                      ; [0, 2^{32}-1], exit with error
    mov eax, 0xffffffff
    cmp rbx, rax
    ja exit1

; ------------------------------------------
; |        Input buffer allocation         |
; ------------------------------------------

    call create_buffer            ; allocate a page-sized buffer

    mov [rel input_buf], rax      ; save returned pointer and initial size
    mov qword [rel input_buf_len], PAGE_SIZE     
    xor r12, r12                  ; r12 - number of occupied bytes in input_buf

; ------------------------------------------
; |      Reading input into input_buf      |
; ------------------------------------------

.read_input:
    mov rax, SYS_READ
    xor edi, edi                  ; fd = STDIN
    mov rsi, [rel input_buf]      ; address = input_buf
    add rsi, r12                  ; address = input_buf + r12 (occupied bytes)
    mov rdx, [rel input_buf_len]  ; size = input_buf_len
    sub rdx, r12                  ; size = input_buf_len - r12 (remaining space)

    syscall                       ; invoke SYS_READ

    cmp rax, -4096                ; check for syscall error
    ja exit1

    test rax, rax                 ; rax = 0 means EOF (all input read)
    jz .end_read_input

    add r12, rax                  ; add newly read bytes to the counter
    cmp r12, [rel input_buf_len]
    jb .read_input                ; occupied bytes < capacity, continue reading

    ; input buffer needs to be expanded

    mov rdi, [rel input_buf]      ; set arguments for expand_buffer
    mov rsi, [rel input_buf_len]

    call expand_buffer            ; double the size of input_buf

    mov [rel input_buf], rax      ; save new pointer
    shl qword [rel input_buf_len], 1 ; update buffer size

    jmp .read_input               ; space is now guaranteed, continue reading


.end_read_input:

; ------------------------------------------
; |      Allocation of buffers A and B     |
; ------------------------------------------

; Allocate buffer A

    call create_buffer            ; create a page-sized buffer

    mov [rel buf_a], rax
    mov qword [rel buf_a_len], PAGE_SIZE

    xor r13, r13                  ; zero out occupied bytes count in buf_a

; Allocate buffer B

    call create_buffer            ; create a page-sized buffer

    mov [rel buf_b], rax
    mov qword [rel buf_b_len], PAGE_SIZE

    xor r14, r14                  ; zero out occupied bytes count in buf_b

; ------------------------------------------
; |     Loading initial string to buf_a    |
; |                                        |
; | r15 - iterator over input_buf          |
; ------------------------------------------

    xor r15, r15                  ; zero out input_buf iterator

.read_init_string:

    mov rcx, [rel input_buf]      ; load base address of input buffer
    add rcx, r15                  ; offset by the number of bytes read so far

    inc r15                       ; advance input iterator

    mov al, [rcx]                 ; al = current character

    cmp al, NEW_LINE_CODE
    je .end_read_init_string      ; first newline marks the end of initial string

    cmp al, MIN_ASCII             ; verify ASCII code is within
    jb exit1                      ; printable range [33, 126]
    cmp al, MAX_ASCII
    ja exit1
    
    push rax                      ; save character on stack

    cmp r13, qword [rel buf_a_len]
    jb .enough_space_a

    mov rdi, [rel buf_a]          ; load arguments for helper function
    mov rsi, [rel buf_a_len]

    call expand_buffer            ; double the size of buf_a

    mov [rel buf_a], rax          ; rax = new address of buf_a
    shl qword [rel buf_a_len], 1

.enough_space_a:
    pop rax                       ; al = current character

    mov rcx, [rel buf_a]          ; rcx = start of buf_a
    add rcx, r13                  ; rcx = first free byte in buf_a

    mov [rcx], al                 ; store character in memory

    inc r13                       ; increment occupied bytes in buf_a

    jmp .read_init_string

.end_read_init_string:


; ------------------------------------------
; |       Loading replacement rules        |
; |                                        |
; | r15 - iterator over input_buf          |
; | rdi - character being defined by rule  |
; ------------------------------------------

    dec r15                       ; step back to the newline ending the initial string

.parse_rules:

    mov rcx, [rel input_buf]      ; load base address of input buffer
    add rcx, r15                  ; offset by bytes read so far

    inc r15                       ; increment read characters count

    mov al, [rcx]                 ; load next character

    cmp al, NEW_LINE_CODE         ; start parsing a new rule
    je .new_rule                  ; if newline character encountered

    cmp al, MIN_ASCII             ; verify ASCII code is within
    jb exit1                      ; range [33, 126]
    cmp al, MAX_ASCII
    ja exit1

    lea r8, [rel rules_len]       ; r8 = base address of rules_len

    inc qword [r8 + rdi * 8]      ; increment replacement length for current char

    cmp r15, r12                  ; check if entire input_buf has been processed
    jne .parse_rules
    jmp exit1                     ; input must end with a newline character


.new_rule:

    cmp r15, r12
    je .end_parse_rules           ; all rules have been loaded

    mov rcx, [rel input_buf]      ; load base address of input buffer
    add rcx, r15                  ; offset by characters read so far

    inc r15                       ; increment read characters count

    mov al, [rcx]                 ; load target character for the rule

    cmp al, MIN_ASCII             ; verify ASCII code is within
    jb exit1                      ; range [33, 126]
    cmp al, MAX_ASCII
    ja exit1

    movzx rdi, al                 ; character for which the rule is being read

    lea r8, [rel rules_len]       ; r8 = pointer to rules length table

    cmp qword [r8 + rdi * 8], 0
    jne exit1                     ; rule for this character already exists

    inc rcx                       ; advance pointer to the first replacement char

    inc qword [r8 + rdi * 8]      ; initialize length to 1 (represents empty string)

    lea r8, [rel rules]           ; r8 = pointer to rules address table
    mov [r8 + rdi * 8], rcx       ; store pointer to the replacement sequence
    jmp .parse_rules


.end_parse_rules:


; ------------------------------------------
; |           Fractal Generation           |
; |                                        |
; | rdi - character currently being replaced|
; | rsi - iterator over replacement rule   |
; | r13 - occupied bytes in buf_a          |
; | r14 - iterator / occupied bytes in buf_b|
; | r15 - iterator over buf_a              |
; ------------------------------------------
; Sequentially generates all states.

    cmp r13, 0
    je .end_generation            ; if initial string is empty, skip generation

    cmp rbx, 0
    je .end_generation            ; edge case: 0 iterations requested

    lea r8, [rel rules]           ; r8 = pointer to rules array
    lea r9, [rel rules_len]       ; r9 = pointer to rules_len array
    
.main_loop:

    cmp qword [rel buf_a_len], 0  ; check if string is empty
    je .end_generation            ; string became empty -> nothing left to generate

    xor r14, r14                  ; reset buf_b iterator
    xor r15, r15                  ; reset buf_a iterator


.loop_buf_a: 

    mov rcx, [rel buf_a]          ; load base pointer of buf_a
    add rcx, r15                  ; point to current character

    inc r15                       ; advance buf_a iterator

    mov al, [rcx]                 ; al = character to be replaced
    movzx rdi, al                 ; rdi = ASCII code of the character

    xor rsi, rsi                  ; reset rule iterator to 0

    cmp qword [r9 + rdi * 8], 1   
    je .end_rule_loop             ; replace with empty string (len == 1)
    ja .rule_loop                 ; replace with sequence (len > 1)

; Handles writing a character that has no replacement rule directly to buf_b

    cmp r14, [rel buf_b_len]      ; check if there is space in buf_b
    jne .no_expand_needed

    push rdi
    push rsi

    mov rdi, [rel buf_b]          ; load arguments for buffer expansion
    mov rsi, [rel buf_b_len]

    call expand_buffer            ; double the size of buf_b

    mov [rel buf_b], rax          ; update buffer pointer
    shl qword [rel buf_b_len], 1  ; update buffer size

    pop rsi
    pop rdi


.no_expand_needed:

    mov rcx, [rel buf_b]          ; calculate target address in buf_b
    add rcx, r14

    inc r14                       ; advance buf_b iterator

    movzx rax, dil                ; al = original character

    mov byte [rcx], al            ; write character to buf_b

    jmp .end_rule_loop

.rule_loop:

    cmp r14, [rel buf_b_len]   
    jne .enough_memory            ; enough space in buf_b for the next character

    push rdi
    push rsi

    mov rdi, [rel buf_b]          ; load arguments for buffer expansion
    mov rsi, [rel buf_b_len]

    call expand_buffer            ; double the size of buf_b

    mov [rel buf_b], rax          ; update buffer pointer
    shl qword [rel buf_b_len], 1  ; update buffer size

    pop rsi
    pop rdi

.enough_memory:

    mov rcx, [rel buf_b]          ; rcx = start of buf_b
    add rcx, r14                  ; rcx = first free byte in buf_b

    inc r14                       ; advance buf_b iterator

    mov rdx, [r8 + rdi * 8]       ; load pointer to replacement string
    add rdx, rsi                  ; point to current character in rule

    inc rsi                       ; advance rule iterator

    movzx rax, byte [rdx]         ; al = replacement character

    mov byte [rcx], al            ; write replacement character to buf_b

    mov rdx, [r9 + rdi * 8]       ; rdx = rule length + 1
    dec rdx                       ; rdx = actual rule length

    cmp rsi, rdx                  ; compare iterator with rule length
    
    je .end_rule_loop             ; rsi == rule length (done)
    jmp .rule_loop                ; rsi < rule length (continue)

.end_rule_loop:

    cmp r15, r13                  ; check if all of buf_a has been processed
    jne .loop_buf_a               ; characters remaining in buf_a


.end_loop_buf_a:

    ; swap buf_a and buf_b for the next iteration

    mov rax, [rel buf_a]          ; swap pointers: buf_a <-> buf_b
    mov rcx, [rel buf_b]
    mov [rel buf_a], rcx
    mov [rel buf_b], rax

    mov rax, [rel buf_a_len]      ; swap sizes: buf_a_len <-> buf_b_len
    mov rcx, [rel buf_b_len]
    mov [rel buf_a_len], rcx
    mov [rel buf_b_len], rax 

    mov r13, r14                  ; update occupied bytes count in buf_a

    dec rbx                       ; main loop runs exactly n times
    jnz .main_loop

.end_generation:

; ------------------------------------------
; |            Printing Output             |
; |                                        |
; | r13 - occupied bytes in buf_a          |
; | r15 - iterator over buf_a              |
; ------------------------------------------

    xor r15, r15

.print_loop:
    cmp r13, r15                  ; check if there are bytes left to print
    je .end_print

    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, [rel buf_a]          ; point to the first unprinted character
    add rsi, r15
    mov rdx, r13                  ; rdx = r13 - r15 (remaining bytes to print)
    sub rdx, r15

    syscall

    cmp rax, -4096                ; check for syscall error
    ja exit1

    add r15, rax                  ; advance iterator by number of bytes written
    jmp .print_loop               ; repeat until all bytes are written

.end_print:

    push NEW_LINE_CODE            

    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, rsp
    mov rdx, 1

    syscall                       ; print trailing newline

    add rsp, 8                    ; clean up stack

    cmp rax, -4096                ; check for syscall error
    ja exit1

    jmp exit0                     ; exit program successfully

; ------------------------------------------
; |            Helper Functions            |
; ------------------------------------------

; ------------------------------------------
; |           Exit with error (1)          |
; ------------------------------------------

exit1:
    mov rbx, 1

    mov rdi, [rel input_buf]      ; address = input_buf
    mov rsi, [rel input_buf_len]  ; size = input_buf_len

    call free_buffer              ; free input_buf

    mov rdi, [rel buf_a]          ; address = buf_a
    mov rsi, [rel buf_a_len]      ; size = buf_a_len

    call free_buffer              ; free buf_a

    mov rdi, [rel buf_b]          ; address = buf_b
    mov rsi, [rel buf_b_len]      ; size = buf_b_len

    call free_buffer              ; free buf_b

    mov rdi, 1
    mov rax, SYS_EXIT
    syscall

; ------------------------------------------
; |          Exit successfully (0)         |
; ------------------------------------------

exit0:
    mov rbx, 0

    mov rdi, [rel input_buf]      ; address = input_buf
    mov rsi, [rel input_buf_len]  ; size = input_buf_len

    call free_buffer              ; free input_buf

    mov rdi, [rel buf_a]          ; address = buf_a
    mov rsi, [rel buf_a_len]      ; size = buf_a_len

    call free_buffer              ; free buf_a

    mov rdi, [rel buf_b]          ; address = buf_b
    mov rsi, [rel buf_b_len]      ; size = buf_b_len

    call free_buffer              ; free buf_b

    mov rdi, 0
    mov rax, SYS_EXIT
    syscall


; ------------------------------------------
; |      Allocates a page-sized buffer     |
; ------------------------------------------

create_buffer:

    mov rax, SYS_MMAP             ; syscall number
    xor rdi, rdi                  ; addr = nullptr
    mov rsi, PAGE_SIZE            ; length = PAGE_SIZE
    mov rdx, PROT_READ | PROT_WRITE 
    mov r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1                    ; fd = -1
    xor r9, r9                    ; offset = 0

    syscall                       ; invoke SYS_MMAP

    cmp rax, -4096                ; check for syscall error
    ja exit1

    ret


; ------------------------------------------
; |        Doubles the buffer size         |
; |                                        |
; | rdi - buffer pointer                   |
; | rsi - current buffer size              |
; ------------------------------------------

expand_buffer:
    push r13
    push r8

    mov r13, rsi
    shl r13, 1

    mov rax, SYS_MREMAP           ; rdi and rsi already hold old_address and old_size
    mov rdx, r13                  ; new_size = 2 * old_size
    mov r10, MREMAP_MAYMOVE
    xor r8, r8                    ; new_address (unused)

    syscall

    cmp rax, -4096                ; check for syscall error
    ja exit1

    pop r8
    pop r13

    ret

; ------------------------------------------
; |         Frees allocated buffer         |
; |                                        |
; | rdi - buffer pointer                   |
; | rsi - buffer size                      |
; | rbx - flag indicating if in exit1      |
; ------------------------------------------

free_buffer:

    mov rax, SYS_MUNMAP

    syscall                       ; unmap buffer

    cmp rax, -4096                ; check for syscall error
    ja .error

    ret

.error:
    cmp rbx, 0                    ; if not already in exit1 (rbx == 0),
    je exit1                      ; jump to exit1

    ret