"""Lossless 4-bit coverage runs with an extended transparent run."""


def encode(pixels):
    output = bytearray()
    i = 0
    while i < len(pixels):
        alpha = pixels[i]
        if not 0 <= alpha <= 15:
            raise ValueError('coverage must fit in four bits')
        limit = 271 if alpha == 0 else 16
        count = 1
        while count < limit and i + count < len(pixels) and pixels[i + count] == alpha:
            count += 1
        if alpha == 0 and count >= 16:
            output.extend((15, count - 16))
        else:
            output.append((alpha << 4) | (count - 1))
        i += count
    return bytes(output)


def decode(data):
    pixels = bytearray()
    i = 0
    while i < len(data):
        value = data[i]
        i += 1
        count = (value & 15) + 1
        if value == 15:
            if i == len(data):
                raise ValueError('truncated transparent run')
            count += data[i]
            i += 1
        pixels.extend([value >> 4] * count)
    return bytes(pixels)
