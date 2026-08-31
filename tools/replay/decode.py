def decode_polyline6(s):
    coords, index, lat, lng = [], 0, 0, 0
    while index < len(s):
        for which in (0, 1):
            shift, result = 0, 0
            while True:
                b = ord(s[index]) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20: break
            d = ~(result >> 1) if (result & 1) else (result >> 1)
            if which == 0: lat += d
            else: lng += d
        coords.append([lat / 1e6, lng / 1e6])
    return coords
