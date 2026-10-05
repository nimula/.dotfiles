# Decode decimal bytes from od to strict UTF-8 without a BOM. Run with LC_ALL=C
# so printf %c emits bytes consistently on Unix and in Git Bash.
function invalid() { exit 1 }
function emit(code) {
  if (code == 0) invalid()
  # Keep normalization idempotent, including repeated BOMs and a leading FEFF
  # code unit after the UTF-16 BOM. Preserve FEFF within the text.
  if (code == 65279 && !emitted) return
  emitted = 1
  if (code < 128) printf "%c", code
  else if (code < 2048) printf "%c%c", 192 + int(code / 64), 128 + code % 64
  else if (code < 65536) printf "%c%c%c", 224 + int(code / 4096), 128 + int(code / 64) % 64, 128 + code % 64
  else printf "%c%c%c%c", 240 + int(code / 262144), 128 + int(code / 4096) % 64, 128 + int(code / 64) % 64, 128 + code % 64
}
function unit(    value) {
  if (position + 1 > count) invalid()
  value = little_endian ? bytes[position] + 256 * bytes[position + 1] : 256 * bytes[position] + bytes[position + 1]
  position += 2
  return value
}
{ for (field = 1; field <= NF; field++) bytes[++count] = $field + 0 }
END {
  position = 1
  if (count >= 4 && ((bytes[1] == 255 && bytes[2] == 254 && bytes[3] == 0 && bytes[4] == 0) ||
      (bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 254 && bytes[4] == 255))) invalid()
  if ((bytes[1] == 255 && bytes[2] == 254) || (bytes[1] == 254 && bytes[2] == 255)) {
    little_endian = bytes[1] == 255
    position = 3
    while (position <= count) {
      code = unit()
      if (code >= 55296 && code <= 56319) {
        low = unit()
        if (low < 56320 || low > 57343) invalid()
        code = 65536 + (code - 55296) * 1024 + low - 56320
      } else if (code >= 56320 && code <= 57343) invalid()
      emit(code)
    }
  } else {
    if (bytes[1] == 239 && bytes[2] == 187 && bytes[3] == 191) position = 4
    while (position <= count) {
      first = bytes[position++]
      if (first < 128) { emit(first); continue }
      if (first >= 194 && first <= 223) { remaining = 1; code = first - 192; minimum = 128 }
      else if (first >= 224 && first <= 239) { remaining = 2; code = first - 224; minimum = 2048 }
      else if (first >= 240 && first <= 244) { remaining = 3; code = first - 240; minimum = 65536 }
      else invalid()
      while (remaining-- > 0) {
        if (position > count) invalid()
        continuation = bytes[position++]
        if (continuation < 128 || continuation > 191) invalid()
        code = 64 * code + continuation - 128
      }
      if (code < minimum || code > 1114111 || (code >= 55296 && code <= 57343)) invalid()
      emit(code)
    }
  }
}
