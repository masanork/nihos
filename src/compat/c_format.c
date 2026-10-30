/* Bounded, allocation-free formatter for nihos freestanding components. */
#include "nihos_c_format.h"
#include <stdint.h>
#include <limits.h>

typedef struct { char *out; size_t capacity; size_t length; int failed; } Writer;
static void put(Writer *writer, char byte) {
    if (writer->length < writer->capacity && writer->out) writer->out[writer->length] = byte;
    if (writer->length == (size_t)INT_MAX) writer->failed = 1;
    else ++writer->length;
}
static void repeat(Writer *writer, char byte, size_t count) {
    while (count-- != 0) put(writer, byte);
}
static size_t text_length(const char *text, int precision) {
    size_t length = 0;
    if (!text) text = "(null)";
    while (text[length] && (precision < 0 || length < (size_t)precision)) ++length;
    return length;
}
static void text(Writer *writer, const char *value, size_t length) {
    if (!value) value = "(null)";
    for (size_t i = 0; i < length; ++i) put(writer, value[i]);
}

enum Length { LEN_DEFAULT, LEN_HH, LEN_H, LEN_L, LEN_LL, LEN_J, LEN_Z, LEN_T };
static uintmax_t unsigned_argument(va_list *arguments, enum Length length) {
    switch (length) {
        case LEN_HH: return (unsigned char)va_arg(*arguments, unsigned int);
        case LEN_H: return (unsigned short)va_arg(*arguments, unsigned int);
        case LEN_L: return va_arg(*arguments, unsigned long);
        case LEN_LL: return va_arg(*arguments, unsigned long long);
        case LEN_J: return va_arg(*arguments, uintmax_t);
        case LEN_Z: return va_arg(*arguments, size_t);
        case LEN_T: return (uintmax_t)va_arg(*arguments, ptrdiff_t);
        default: return va_arg(*arguments, unsigned int);
    }
}
static intmax_t signed_argument(va_list *arguments, enum Length length) {
    switch (length) {
        case LEN_HH: return (signed char)va_arg(*arguments, int);
        case LEN_H: return (short)va_arg(*arguments, int);
        case LEN_L: return va_arg(*arguments, long);
        case LEN_LL: return va_arg(*arguments, long long);
        case LEN_J: return va_arg(*arguments, intmax_t);
        case LEN_Z: return (intmax_t)va_arg(*arguments, ptrdiff_t);
        case LEN_T: return va_arg(*arguments, ptrdiff_t);
        default: return va_arg(*arguments, int);
    }
}
static int decimal(const char **cursor) {
    int value = 0;
    while (**cursor >= '0' && **cursor <= '9') {
        const int digit = *(*cursor)++ - '0';
        value = value > (INT_MAX - digit) / 10 ? INT_MAX : value * 10 + digit;
    }
    return value;
}
static void number(Writer *writer, uintmax_t value, unsigned base, int upper,
                   char sign, const char *prefix, int width, int precision,
                   int left, int zero) {
    char digits[sizeof(uintmax_t) * CHAR_BIT];
    size_t used = 0;
    const char *alphabet = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (value != 0 || precision != 0) {
        do { digits[used++] = alphabet[value % base]; value /= base; } while (value != 0);
    }
    const size_t prefix_length = prefix ? text_length(prefix, -1) : 0;
    const size_t zeros = precision > 0 && (size_t)precision > used ? (size_t)precision - used : 0;
    const size_t content = (sign ? 1u : 0u) + prefix_length + zeros + used;
    const size_t padding = width > 0 && (size_t)width > content ? (size_t)width - content : 0;
    if (!left && !zero) repeat(writer, ' ', padding);
    if (sign) put(writer, sign);
    if (prefix_length) text(writer, prefix, prefix_length);
    if (!left && zero) repeat(writer, '0', padding);
    repeat(writer, '0', zeros);
    while (used != 0) put(writer, digits[--used]);
    if (left) repeat(writer, ' ', padding);
}

int NIH_C_FORMAT_NAME(vsnprintf)(char *output, size_t capacity,
                                const char *format, va_list supplied) {
    if (!format || (capacity != 0 && !output)) return -1;
    Writer writer = { output, capacity ? capacity - 1 : 0, 0, 0 };
    va_list arguments;
    va_copy(arguments, supplied);
    while (*format && !writer.failed) {
        if (*format != '%') { put(&writer, *format++); continue; }
        ++format;
        int left=0, plus=0, space=0, alternate=0, zero=0;
        for (;;) {
            if (*format=='-') left=1;
            else if (*format=='+') plus=1;
            else if (*format==' ') space=1;
            else if (*format=='#') alternate=1;
            else if (*format=='0') zero=1;
            else break;
            ++format;
        }
        int width = 0;
        if (*format == '*') { width=va_arg(arguments,int); ++format; if (width<0) { left=1; width=width==INT_MIN ? INT_MAX : -width; } }
        else width=decimal(&format);
        int precision = -1;
        if (*format == '.') {
            ++format;
            if (*format == '*') { precision=va_arg(arguments,int); ++format; if (precision<0) precision=-1; }
            else precision=decimal(&format);
            zero=0;
        }
        enum Length length=LEN_DEFAULT;
        if (*format=='h') { ++format; length=*format=='h' ? (++format,LEN_HH) : LEN_H; }
        else if (*format=='l') { ++format; length=*format=='l' ? (++format,LEN_LL) : LEN_L; }
        else if (*format=='j') { ++format; length=LEN_J; }
        else if (*format=='z') { ++format; length=LEN_Z; }
        else if (*format=='t') { ++format; length=LEN_T; }
        const char conversion=*format ? *format++ : '\0';
        if (conversion=='%') { put(&writer,'%'); continue; }
        if (conversion=='c') {
            const size_t padding=width>1 ? (size_t)width-1 : 0;
            if (!left) repeat(&writer,' ',padding);
            put(&writer,(char)va_arg(arguments,int));
            if (left) repeat(&writer,' ',padding);
            continue;
        }
        if (conversion=='s') {
            const char *value=va_arg(arguments,const char *);
            const size_t used=text_length(value,precision);
            const size_t padding=width>0 && (size_t)width>used ? (size_t)width-used : 0;
            if (!left) repeat(&writer,' ',padding);
            text(&writer,value,used);
            if (left) repeat(&writer,' ',padding);
            continue;
        }
        if (conversion=='d' || conversion=='i') {
            const intmax_t signed_value=signed_argument(&arguments,length);
            const char sign=signed_value<0 ? '-' : plus ? '+' : space ? ' ' : 0;
            const uintmax_t magnitude=signed_value<0 ? (uintmax_t)0-(uintmax_t)signed_value : (uintmax_t)signed_value;
            number(&writer,magnitude,10,0,sign,NULL,width,precision,left,zero);
            continue;
        }
        if (conversion=='u' || conversion=='o' || conversion=='x' || conversion=='X' || conversion=='p') {
            uintmax_t value;
            unsigned base=10;
            const char *prefix=NULL;
            if (conversion=='p') { value=(uintptr_t)va_arg(arguments,void *); base=16; prefix="0x"; }
            else {
                value=unsigned_argument(&arguments,length);
                if (conversion=='o') base=8;
                else if (conversion=='x' || conversion=='X') base=16;
                if (alternate && value) prefix=base==8 ? "0" : conversion=='X' ? "0X" : "0x";
            }
            number(&writer,value,base,conversion=='X',0,prefix,width,precision,left,zero);
            continue;
        }
        writer.failed=1;
    }
    va_end(arguments);
    if (capacity && output) output[writer.length < writer.capacity ? writer.length : writer.capacity] = '\0';
    return writer.failed ? -1 : (int)writer.length;
}

int NIH_C_FORMAT_NAME(snprintf)(char *output, size_t capacity,
                               const char *format, ...) {
    va_list arguments;
    va_start(arguments,format);
    const int result=NIH_C_FORMAT_NAME(vsnprintf)(output,capacity,format,arguments);
    va_end(arguments);
    return result;
}
