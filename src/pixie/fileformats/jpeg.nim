import pixie/common, pixie/images, pixie/masks, sequtils, strutils, chroma, std/decls

# This JPEG decoder is loosely based on stb_image which is public domain.

# JPEG is a complex format, this decoder only supports the most common features:
# * yCbCr format
# * gray scale format
# * 4:4:4, 4:2:2, 4:1:1, 4:2:0 resampling modes
# * progressive
# * restart markers

# * https://github.com/daviddrysdale/libjpeg
# * https://www.youtube.com/watch?v=Kv1Hiv3ox8I
# * https://dev.exiv2.org/projects/exiv2/wiki/The_Metadata_in_JPEG_files
# * https://www.media.mit.edu/pia/Research/deepview/exif.html
# * https://www.ccoderun.ca/programming/2017-01-31_jpeg/
# * http://imrannazar.com/Let%27s-Build-a-JPEG-Decoder%3A-Concepts
# * https://github.com/nothings/stb/blob/master/stb_image.h
# * https://yasoob.me/posts/understanding-and-writing-jpeg-decoder-in-python/
# * https://www.w3.org/Graphics/JPEG/itu-t81.pdf

const
  fastBits = 9
  jpgStartOfImage* = [0xFF.uint8, 0xD8]
  deZigZag = [
    uint8 00, 01, 08, 16, 09, 02, 03, 10,
    uint8 17, 24, 32, 25, 18, 11, 04, 05,
    uint8 12, 19, 26, 33, 40, 48, 41, 34,
    uint8 27, 20, 13, 06, 07, 14, 21, 28,
    uint8 35, 42, 49, 56, 57, 50, 43, 36,
    uint8 29, 22, 15, 23, 30, 37, 44, 51,
    uint8 58, 59, 52, 45, 38, 31, 39, 46,
    uint8 53, 60, 61, 54, 47, 55, 62, 63
  ]
  bitMasks = [ # (1 shr n) - 1
    0.uint32, 1, 3, 7, 15, 31, 63, 127, 255, 511,
    1023, 2047, 4095, 8191, 16383, 32767, 65535
  ]
  biases = [ # (-1 shl n) + 1
    0.int32, -1, -3, -7, -15, -31, -63, -127, -255,
    -511, -1023, -2047, -4095, -8191, -16383, -32767
  ]

type
  Huffman = object
    codes: array[256, uint16]
    symbols: array[256, uint8]
    sizes: array[257, uint8]
    deltas: array[17, int]
    maxCodes: array[18, int]
    fast: array[1 shl fastBits, uint8]

  Component = object
    id, quantizationTableId: uint8
    yScale, xScale: int
    width, height: int
    widthStride, heightStride: int
    huffmanDC, huffmanAC: int
    dcPred: int
    widthCoeff, heightCoeff: int
    coeff, lineBuf: seq[uint8]
    blocks: seq[seq[array[64, int16]]]
    channel: Mask

  DecoderState = object
    buffer: seq[uint8]
    pos, bitCount: int
    bits: uint32
    hitEnd: bool
    imageHeight, imageWidth: int
    quantizationTables: array[4, array[64, uint8]]
    huffmanTables: array[2, array[4, Huffman]] # 0 = DC, 1 = AC
    components: seq[Component]
    scanComponents: int
    spectralStart, spectralEnd: int
    successiveApproxLow, successiveApproxHigh: int
    maxYScale, maxXScale: int
    mcuWidth, mcuHeight, numMcuWide, numMcuHigh: int
    componentOrder: seq[int]
    progressive: bool
    restartInterval: int
    todo: int
    eobRun: int

when defined(release):
  {.push checks: off.}

template failInvalid(reason = "unable to load") =
  ## Throw exception with a reason.
  raise newException(PixieError, "Invalid JPEG, " & reason)

template clampByte(x): uint8 =
  ## Clamp integer into byte range.
  clamp(x, 0, 0xFF).uint8

proc readUint8(state: var DecoderState): uint8 =
  ## Reads a byte from the input stream.
  if state.pos >= state.buffer.len:
    failInvalid()
  result = state.buffer[state.pos]
  inc state.pos

proc readUint16be(state: var DecoderState): uint16 =
  ## Reads uint16 big-endian from the input stream.
  (state.readUint8().uint16 shl 8) or state.readUint8()

proc skipBytes(state: var DecoderState, n: int) =
  ## Skips a number of bytes.
  if state.pos + n > state.buffer.len:
    failInvalid()
  state.pos += n

proc skipChunk(state: var DecoderState) =
  ## Skips current chunk.
  let len = state.readUint16be() - 2
  state.skipBytes(len.int)

proc decodeDRI(state: var DecoderState) =
  ## Decode Define Restart Interval
  var len = state.readUint16be() - 2
  if len != 2:
    failInvalid("invalid DRI length")
  state.restartInterval = state.readUint16be().int

proc decodeDQT(state: var DecoderState) =
  ## Decode Define Quantization Table(s)
  var len = state.readUint16be() - 2
  while len > 0:
    let
      info = state.readUint8()
      tableId = info and 15
      precision = info shr 4
    if precision != 0:
      failInvalid("unsupported quantization table precision")
    if tableId > 3:
      failInvalid()
    for i in 0 ..< 64:
      state.quantizationTables[tableId][deZigZag[i]] = state.readUint8()
    len -= 65
  if len != 0:
    failInvalid("DQT table length did not match")

proc buildHuffman(huffman: var Huffman, counts: array[16, uint8]) =
  ## Builds the huffman data structure.
  block:
    var k: int
    for i in 0.uint8 ..< 16:
      for j in 0.uint8 ..< counts[i]:
        if k notin 0 ..< 256:
          failInvalid()
        huffman.sizes[k] = i + 1
        inc k
    huffman.sizes[k] = 0

  var code, j: int
  for i in 1.uint8 .. 16:
    huffman.deltas[i] = j - code
    if huffman.sizes[j] == i:
      while huffman.sizes[j] == i:
        huffman.codes[j] = code.uint16
        inc code
        inc j
      if code - 1 >= 1 shl i:
        failInvalid()
    huffman.maxCodes[i] = code shl (16 - i)
    code = code shl 1
  huffman.maxCodes[17] = int.high

  for i in 0 ..< huffman.fast.len:
    huffman.fast[i] = 255

  for i in 0 ..< j:
    let size = huffman.sizes[i]
    if size <= fastBits:
      let fast = huffman.codes[i].int shl (fastBits - size)
      for k in 0 ..< 1 shl (fastBits - size):
        huffman.fast[fast + k] = i.uint8

proc decodeDHT(state: var DecoderState) =
  ## Decode Define Huffman Table
  var len = state.readUint16be() - 2
  while len > 0:
    let
      info = state.readUint8()
      tableId = info and 15
      tableCurrent = info shr 4 # DC or AC

    if tableCurrent > 1 or tableId > 3:
      failInvalid()

    var
      counts: array[16, uint8]
      numSymbols: uint8
    for i in 0 ..< 16:
      counts[i] = state.readUint8()
      numSymbols += counts[i]

    len -= 17

    state.huffmanTables[tableCurrent][tableId] = Huffman()
    state.huffmanTables[tableCurrent][tableId].buildHuffman(counts)

    for i in 0.uint8 ..< numSymbols:
      state.huffmanTables[tableCurrent][tableId].symbols[i] = state.readUint8()

    len -= numSymbols

  if len != 0:
    failInvalid()

proc decodeSOF0(state: var DecoderState) =
  ## Decode start of Frame
  var len = state.readUint16be() - 2

  let precision = state.readUint8()
  if precision != 8:
    failInvalid("unsupported bit depth, must be 8")

  state.imageHeight = state.readUint16be().int
  state.imageWidth = state.readUint16be().int

  if state.imageHeight == 0:
    failInvalid("image invalid 0 height")
  if state.imageWidth == 0:
    failInvalid("image invalid 0 width")

  let numComponents = state.readUint8().int
  if numComponents notin {1, 3}:
    failInvalid("unsupported component count, must be 1 or 3")

  for i in 0 ..< numComponents:
    var component = Component()
    component.id = state.readUint8()
    let
      info = state.readUint8()
      vertical = info and 15
      horizontal = info shr 4
      quantizationTableId = state.readUint8()

    if quantizationTableId > 3:
      failInvalid("invalid quantization table id")

    if vertical == 0 or vertical > 4 or horizontal == 0 or horizontal > 4:
      failInvalid("invalid component scaling factor")

    component.xScale = vertical.int
    component.yScale = horizontal.int
    component.quantizationTableId = quantizationTableId
    state.components.add(component)

  for component in state.components.mitems:
    state.maxXScale = max(state.maxXScale, component.xScale)
    state.maxYScale = max(state.maxYScale, component.yScale)

  state.mcuWidth = state.maxYScale * 8
  state.mcuHeight = state.maxXScale * 8
  state.numMcuWide =
    (state.imageWidth + state.mcuWidth - 1) div state.mcuWidth
  state.numMcuHigh =
    (state.imageHeight + state.mcuHeight - 1) div state.mcuHeight

  for component in state.components.mitems:
    component.width = (
      state.imageWidth *
      component.yScale +
      state.maxYScale - 1
    ) div state.maxYScale
    component.height = (
      state.imageHeight *
      component.xScale +
      state.maxXScale - 1
    ) div state.maxXScale

    # Allocate block data structures.
    component.blocks = newSeqWith(
      component.width,
      newSeq[array[64, int16]](
        component.height
      )
    )

    component.widthStride = state.numMcuWide * component.yScale * 8
    component.heightStride = state.numMcuHigh * component.xScale * 8

    component.channel = newMask(
      component.widthStride, component.heightStride
    )

    if state.progressive:
      component.widthCoeff = component.widthStride div 8
      component.heightCoeff = component.heightStride div 8
      component.coeff.setLen(
        component.widthStride * component.heightStride
      )

proc decodeSOF1(state: var DecoderState) =
  failInvalid("unsupported extended sequential DCT format")

proc decodeSOF2(state: var DecoderState) =
  ## Decode Start of Image (Progressive DCT format)
  # Same as SOF0
  state.decodeSOF0()
  state.progressive = true

proc reset(state: var DecoderState) =
  ## Rests the decoder state need for reset markers.
  state.bits = 0
  state.bitCount = 0
  for component in 0 ..< state.components.len:
    state.components[component].dcPred = 0
  state.hitEnd = false
  if state.restartInterval != 0:
    state.todo = state.restartInterval
  else:
    state.todo = 0x7fffffff
  state.eobRun = 0

proc decodeSOS(state: var DecoderState) =
  ## Decode Start of Scan - header before the block data.
  var len = state.readUint16be() - 2

  state.scanComponents = state.readUint8().int

  if state.scanComponents > state.components.len:
    failInvalid("extra components")

  if state.scanComponents notin [1, 3]:
    failInvalid("unsupported scan component count")

  state.componentOrder.setLen(0)

  for i in 0 ..< state.scanComponents:
    let
      id = state.readUint8()
      info = state.readUint8()
      huffmanAC = info and 15
      huffmanDC = info shr 4

    if huffmanAC > 3 or huffmanDC > 3:
      failInvalid()

    var component: int
    while component < 3:
      if state.components[component].id == id:
        break
      inc component
    if component == 3:
      failInvalid() # Not found

    state.components[component].huffmanAC = huffmanAC.int
    state.components[component].huffmanDC = huffmanDC.int
    state.componentOrder.add(component)

  state.spectralStart = state.readUint8().int
  state.spectralEnd = state.readUint8().int

  let aa = state.readUint8().int
  state.successiveApproxLow = aa and 15
  state.successiveApproxHigh = aa shr 4

  state.reset()

  if state.progressive:
    if state.spectralStart > 63 or state.spectralEnd > 63:
      failInvalid()
    if state.spectralEnd > state.spectralEnd:
      failInvalid()
    if state.successiveApproxHigh > 13 or state.successiveApproxLow > 13:
      failInvalid()
  else:
    if state.spectralStart != 0:
      failInvalid()
    if state.successiveApproxHigh != 0 or state.successiveApproxLow != 0:
      failInvalid()
    state.spectralEnd = 63

  len -= 4 + 2 * state.scanComponents.uint16

  if len != 0:
    failInvalid()

proc fillBits(state: var DecoderState) =
  ## When we are low on bits, we need to call this to populate some more.
  while true:
    let b = if state.hitEnd:
        0.uint32
      else:
        state.readUint8().uint32
    if b == 0xFF:
      var c = state.readUint8()
      while c == 0xFF: c = state.readUint8()
      if c != 0:
        dec state.pos
        dec state.pos
        state.hitEnd = true
        return
    state.bits = state.bits or (b shl (24 - state.bitCount))
    state.bitCount += 8

    if not(state.bitCount <= 24):
      break

proc huffmanDecode(state: var DecoderState, tableCurrent, table: int): uint8 =
  ## Decode a uint8 from the huffman table.
  if state.bitCount < 16:
    state.fillBits()

  let
    fastId = (state.bits shr (32 - fastBits)) and ((1 shl fastBits) - 1)
    fast = state.huffmanTables[tableCurrent][table].fast[fastId]
  if fast < 255:
    let size = state.huffmanTables[tableCurrent][table].sizes[fast].int
    if size > state.bitCount:
      failInvalid()
    state.bits = state.bits shl size
    state.bitCount -= size
    return state.huffmanTables[tableCurrent][table].symbols[fast]

  var
    tmp = (state.bits shr 16).int
    i = fastBits + 1
  while i < state.huffmanTables[tableCurrent][table].maxCodes.len:
    if tmp < state.huffmanTables[tableCurrent][table].maxCodes[i]:
      break
    inc i

  if i == 17 or i > state.bitCount:
    failInvalid()

  let symbolId = (state.bits shr (32 - i)).int +
    state.huffmanTables[tableCurrent][table].deltas[i]

  state.bits = state.bits shl i
  state.bitCount -= i
  return state.huffmanTables[tableCurrent][table].symbols[symbolId]

template lrot(value: uint32, shift: int): uint32 =
  ## Left rotate - used for huffman decoding.
  (value shl shift) or (value shr (32 - shift))

proc getBit(state: var DecoderState): int =
  ## Get a single bit.
  if state.bitCount < 1:
    state.fillBits()
  let k = state.bits
  state.bits = state.bits shl 1
  dec state.bitCount
  return (k.int and 0x80000000.int)

proc getBitsAsSignedInt(state: var DecoderState, n: int): int =
  ## Get n number of bits as a signed integer.
  if n notin 0 .. 16:
    failInvalid()
  if state.bitCount < n:
    state.fillBits()
  let sign = cast[int32](state.bits) shr 31
  var k = lrot(state.bits, n)
  state.bits = k and (not bitMasks[n])
  k = k and bitMasks[n]
  state.bitCount -= n
  result = k.int + (biases[n] and (not sign))

proc getBitsAsUnsignedInt(state: var DecoderState, n: int): int =
  ## Get n number of bits as a unsigned integer.
  if n notin 0 .. 16:
    failInvalid()
  if state.bitCount < n:
    state.fillBits()
  var k = lrot(state.bits, n)
  state.bits = k and (not bitMasks[n])
  k = k and bitMasks[n]
  state.bitCount -= n
  return k.int

{.push overflowChecks: off, rangeChecks: off.}

proc decodeRegularBlock(
  state: var DecoderState, component: int, data: var array[64, int16]
) =
  ## Decodes a whole block.
  let t = state.huffmanDecode(0, state.components[component].huffmanDC).int
  if t < 0:
    failInvalid()

  let
    diff = if t == 0:
      0
    else:
      state.getBitsAsSignedInt(t)
    dc = state.components[component].dcPred + diff
  state.components[component].dcPred = dc
  data[0] = dc.int16

  var i = 1
  while true:
    let
      rs = state.huffmanDecode(1, state.components[component].huffmanAC)
      s = rs and 15
      r = rs shr 4
    if s == 0:
      if rs != 0xF0:
        break
      i += 16
    else:
      i += r.int
      if i notin 0 ..< 64:
        failInvalid()
      let zig = deZigZag[i]
      data[zig] = state.getBitsAsSignedInt(s.int).int16
      inc i

    if not(i < 64):
      break

proc decodeProgressiveBlock(
  state: var DecoderState, component: int, data: var array[64, int16]
) =
  ## Decode a Progressive Start Block
  if state.spectralEnd != 0:
    failInvalid("can't merge dc and ac")

  if state.successiveApproxHigh == 0:
    let t = state.huffmanDecode(0, state.components[component].huffmanDC).int
    if t < 0 or t > 15:
      failInvalid()
    let
      diff = if t != 0:
        state.getBitsAsSignedInt(t)
      else:
        0
    let
      dc = state.components[component].dcPred + diff
    state.components[component].dcPred = dc
    data[0] = (dc * (1 shl state.successiveApproxLow)).int16

  else:
    if getBit(state) != 0:
      data[0] += (1 shl state.successiveApproxLow).int16

proc decodeProgressiveContinuationBlock(
  state: var DecoderState, component: int, data: var array[64, int16]
) =
  ## Decode a Progressive Continuation Block
  if state.spectralStart == 0:
    failInvalid("can't merge progressive blocks")

  if state.successiveApproxHigh == 0:
    var shift = state.successiveApproxLow

    if state.eobRun != 0:
      dec state.eobRun
      return

    var k = state.spectralStart
    while true:
      let
        rs = state.huffmanDecode(1, state.components[component].huffmanAC)
      if rs < 0:
        failInvalid("bad huffman code")
      let
        s = rs and 15
        r = rs.int shr 4
      if s == 0:
        if r < 15:
          state.eobRun = 1 shl r
          if r != 0:
            state.eobRun += state.getBitsAsUnsignedInt(r)
          dec state.eobRun
          break
        k += 16
      else:
        k += r.int
        if k notin 0 ..< 64:
          failInvalid()
        let zig = deZigZag[k]
        inc k
        if s >= 15:
          failInvalid()
        data[zig] = (state.getBitsAsSignedInt(s.int) * (1 shl shift)).int16

      if not(k <= state.spectralEnd):
        break

  else:
    var bit = 1 shl state.successiveApproxLow

    if state.eobRun != 0:
      dec state.eobRun
      for k in state.spectralStart ..< state.spectralEnd:
        let zig = deZigZag[k]
        if data[zig] != 0:
          if state.getBit() != 0:
            if (data[zig] and bit) == 0:
              if data[zig] > 0:
                data[zig] += bit.int16
              else:
                data[zig] -= bit.int16
    else:
      var k = state.spectralStart
      while true:
        let
          rs = state.huffmanDecode(1, state.components[component].huffmanAC)
        if rs < 0:
          failInvalid("bad huffman code")
        var
          s = rs.int and 15
          r = rs.int shr 4
        if s == 0:
          if r < 15:
            state.eobRun = (1 shl r) - 1
            if r != 0:
              state.eobRun += state.getBitsAsUnsignedInt(r)
            r = 64 # force end of block
          else:
            discard
        else:
          if s != 1:
            failInvalid("bad huffman code")
          if getBit(state) != 0:
            s = bit.int
          else:
            s = -bit.int

        while k <= state.spectralEnd:
          let zig = deZigZag[k]
          inc k
          if data[zig] != 0:
            if getBit(state) != 0:
              if (data[zig] and bit) == 0:
                if data[zig] > 0:
                  data[zig] += bit.int16
                else:
                  data[zig] -= bit.int16
          else:
            if r == 0:
              data[zig] = s.int16
              break
            dec r

        if not (k <= state.spectralEnd):
          break

template idct1D(s0, s1, s2, s3, s4, s5, s6, s7: int32) =
  ## Inverse discrete cosine transform 1D
  template f2f(x: float32): int32 = (x * 4096 + 0.5).int32
  template fsh(x: int32): int32 = x * 4096
  p2 = s2
  p3 = s6
  p1 = (p2 + p3) * f2f(0.5411961f)
  t2 = p1 + p3*f2f(-1.847759065f)
  t3 = p1 + p2*f2f(0.765366865f)
  p2 = s0
  p3 = s4
  t0 = fsh(p2 + p3)
  t1 = fsh(p2 - p3)
  x0 = t0 + t3
  x3 = t0 - t3
  x1 = t1 + t2
  x2 = t1 - t2
  t0 = s7
  t1 = s5
  t2 = s3
  t3 = s1
  p3 = t0 + t2
  p4 = t1 + t3
  p1 = t0 + t3
  p2 = t1 + t2
  p5 = (p3 + p4) * f2f(1.175875602f)
  t0 = t0 * f2f(0.298631336f)
  t1 = t1 * f2f(2.053119869f)
  t2 = t2 * f2f(3.072711026f)
  t3 = t3 * f2f(1.501321110f)
  p1 = p5 + p1*f2f(-0.899976223f)
  p2 = p5 + p2*f2f(-2.562915447f)
  p3 = p3 * f2f(-1.961570560f)
  p4 = p4 * f2f(-0.390180644f)
  t3 += p1 + p4
  t2 += p2 + p3
  t1 += p2 + p4
  t0 += p1 + p3

proc idctBlock(component: var Component, offset: int, data: array[64, int16]) =
  ## Inverse discrete cosine transform whole block.
  var values: array[64, int32]
  for i in 0 ..< 8:
    if data[i + 8] == 0 and
      data[i + 16] == 0 and
      data[i + 24] == 0 and
      data[i + 32] == 0 and
      data[i + 40] == 0 and
      data[i + 48] == 0 and
      data[i + 56] == 0:
      let dcterm = data[i] * 4
      values[i + 0] = dcterm
      values[i + 8] = dcterm
      values[i + 16] = dcterm
      values[i + 24] = dcterm
      values[i + 32] = dcterm
      values[i + 40] = dcterm
      values[i + 48] = dcterm
      values[i + 56] = dcterm
    else:
      var t0, t1, t2, t3, p1, p2, p3, p4, p5, x0, x1, x2, x3: int32
      idct1D(
        data[i + 0],
        data[i + 8],
        data[i + 16],
        data[i + 24],
        data[i + 32],
        data[i + 40],
        data[i + 48],
        data[i + 56]
      )
      x0 += 512
      x1 += 512
      x2 += 512
      x3 += 512
      values[i + 0] = (x0 + t3) shr 10
      values[i + 56] = (x0 - t3) shr 10
      values[i + 8] = (x1 + t2) shr 10
      values[i + 48] = (x1 - t2) shr 10
      values[i + 16] = (x2 + t1) shr 10
      values[i + 40] = (x2 - t1) shr 10
      values[i + 24] = (x3 + t0) shr 10
      values[i + 32] = (x3 - t0) shr 10

  for i in 0 ..< 8:
    let
      valuesPos = i * 8
      outPos = i * component.widthStride + offset

    var t0, t1, t2, t3, p1, p2, p3, p4, p5, x0, x1, x2, x3: int32
    idct1D(
      values[valuesPos + 0],
      values[valuesPos + 1],
      values[valuesPos + 2],
      values[valuesPos + 3],
      values[valuesPos + 4],
      values[valuesPos + 5],
      values[valuesPos + 6],
      values[valuesPos + 7]
    )

    x0 += 65536 + (128 shl 17)
    x1 += 65536 + (128 shl 17)
    x2 += 65536 + (128 shl 17)
    x3 += 65536 + (128 shl 17)

    component.channel.data[outPos + 0] = clampByte((x0 + t3) shr 17)
    component.channel.data[outPos + 7] = clampByte((x0 - t3) shr 17)
    component.channel.data[outPos + 1] = clampByte((x1 + t2) shr 17)
    component.channel.data[outPos + 6] = clampByte((x1 - t2) shr 17)
    component.channel.data[outPos + 2] = clampByte((x2 + t1) shr 17)
    component.channel.data[outPos + 5] = clampByte((x2 - t1) shr 17)
    component.channel.data[outPos + 3] = clampByte((x3 + t0) shr 17)
    component.channel.data[outPos + 4] = clampByte((x3 - t0) shr 17)

proc decodeBlock(state: var DecoderState, comp, row, column: int) =
  ## Decodes a block.
  var data {.byaddr.} = state.components[comp].blocks[row][column]
  if state.progressive:
    if state.spectralStart == 0:
      state.decodeProgressiveBlock(comp, data)
    else:
      state.decodeProgressiveContinuationBlock(comp, data)
  else:
    state.decodeRegularBlock(comp, data)

template checkReset(state: var DecoderState) =
  ## Check if we might have run into a reset marker, then deal with it.
  dec state.todo
  if state.todo <= 0:
    if state.bitCount < 24:
      state.fillBits()

    if state.buffer[state.pos] == 0xFF:
      if state.buffer[state.pos+1] in {0xD0 .. 0xD7}:
        state.pos += 2
      else:
        failInvalid("did not get expected reset marker")
    state.reset()

proc decodeBlocks(state: var DecoderState) =
  ## Decodes scan data blocks that follow a SOS block.
  if state.scanComponents == 1:
    # Single component pass.

    let
      comp = state.componentOrder[0]
      w = (state.components[comp].width + 7) shr 3
      h = (state.components[comp].height + 7) shr 3
    for column in 0 ..< h:
      for row in 0 ..< w:
        state.decodeBlock(comp, row, column)
        state.checkReset()
  else:
    # Interleaved regular component pass.
    for mcuY in 0 ..< state.numMcuHigh:
      for mcuX in 0 ..< state.numMcuWide:
        for comp in state.componentOrder:
          for compY in 0 ..< state.components[comp].xScale:
            for compX in 0 ..< state.components[comp].yScale:
              let
                row = (mcuX * state.components[comp].yScale + compX)
                col = (mcuY * state.components[comp].xScale + compY)
              state.decodeBlock(comp, row, col)
        state.checkReset()

proc quantizationAndIDCTPass(state: var DecoderState) =
  ## Does quantization and IDCT.
  for comp in 0 ..< state.components.len:
    let
      w = (state.components[comp].width + 7) shr 3
      h = (state.components[comp].height + 7) shr 3

    for column in 0 ..< h:
      for row in 0 ..< w:
        var data = state.components[comp].blocks[row][column]

        for i in 0 ..< 64:
          let qTableId = state.components[comp].quantizationTableId
          if qTableId.int notin 0 ..< state.quantizationTables.len:
            failInvalid()
          data[i] = data[i] * state.quantizationTables[qTableId][i].int16

        state.components[comp].idctBlock(
          state.components[comp].widthStride * column * 8 + row * 8,
          data
        )

proc magnifyXBy2(mask: Mask): Mask =
  ## Smooth magnify by power of 2 only in the X direction.
  result = newMask(mask.width * 2, mask.height)
  for y in 0 ..< mask.height:
    for x in 0 ..< mask.width:
      let n = 3 * mask.unsafe[x, y].uint16
      if x == 0:
        result.unsafe[x * 2 + 0, y] = mask.unsafe[x, y]
        result.unsafe[x * 2 + 1, y] = ((n + mask.unsafe[x+1, y].uint16 + 2) div 4).uint8
      elif x == mask.width - 1:
        result.unsafe[x * 2 + 0, y] = ((n + mask.unsafe[x-1, y].uint16 + 2) div 4).uint8
        result.unsafe[x * 2 + 1, y] = mask.unsafe[x, y]
      else:
        result.unsafe[x * 2 + 0, y] = ((n + mask.unsafe[x-1, y].uint16) div 4).uint8
        result.unsafe[x * 2 + 1, y] = ((n + mask.unsafe[x+1, y].uint16) div 4).uint8

proc magnifyYBy2(mask: Mask): Mask =
  ## Smooth magnify by power of 2 only in the Y direction.
  result = newMask(mask.width, mask.height * 2)
  for y in 0 ..< mask.height:
    for x in 0 ..< mask.width:
      let n = 3 * mask.unsafe[x, y].uint16
      if y == 0:
        result.unsafe[x, y * 2 + 0] = mask.unsafe[x, y]
        result.unsafe[x, y * 2 + 1] = ((n + mask.unsafe[x, y+1].uint16 + 2) div 4).uint8
      elif y == mask.height - 1:
        result.unsafe[x, y * 2 + 0] = ((n + mask.unsafe[x, y-1].uint16 + 2) div 4).uint8
        result.unsafe[x, y * 2 + 1] = mask.unsafe[x, y]
      else:
        result.unsafe[x, y * 2 + 0] = ((n + mask.unsafe[x, y-1].uint16) div 4).uint8
        result.unsafe[x, y * 2 + 1] = ((n + mask.unsafe[x, y+1].uint16) div 4).uint8

proc yCbCrToRgbx(py, pcb, pcr: uint8): ColorRGBX =
  ## Takes a 3 component yCbCr outputs and populates image.
  template float2Fixed(x: float32): int =
    (x * 4096 + 0.5).int shl 8

  let
    yFixed = (py.int shl 20) + (1 shl 19)
    cb = pcb.int - 128
    cr = pcr.int - 128
  var
    r = yFixed + cr * float2Fixed(1.40200)
    g = yFixed +
      (cr * -float2Fixed(0.71414)) +
      ((cb * -float2Fixed(0.34414)) and -65536)
    b = yFixed + cb * float2Fixed(1.77200)
  result.r = clampByte(r shr 20)
  result.g = clampByte(g shr 20)
  result.b = clampByte(b shr 20)
  result.a = 255

proc grayScaleToRgbx(gray: uint8): ColorRGBX =
  ## Takes a single gray scale component output and populates image.
  let g = gray
  result.r = g
  result.g = g
  result.b = g
  result.a = 255

{.pop.}

proc buildImage(state: var DecoderState): Image =
  ## Takes a jpeg image object and builds a pixie Image from it.

  if state.components.len == 3:
    for component in state.components.mitems:
      while component.yScale < state.maxYScale:
        component.channel = component.channel.magnifyXBy2()
        component.yScale *= 2

      while component.xScale < state.maxXScale:
        component.channel = component.channel.magnifyYBy2()
        component.xScale *= 2

  result = newImage(state.imageWidth, state.imageHeight)

  if state.components.len == 3:
    let
      cy = state.components[0].channel
      cb = state.components[1].channel
      cr = state.components[2].channel
    for y in 0 ..< state.imageHeight:
      for x in 0 ..< state.imageWidth:
        result.unsafe[x, y] = yCbCrToRgbx(
          cy.unsafe[x, y],
          cb.unsafe[x, y],
          cr.unsafe[x, y],
        )

  elif state.components.len == 1:
    let
      cy = state.components[0].channel
    for y in 0 ..< state.imageHeight:
      for x in 0 ..< state.imageWidth:
        result.unsafe[x, y] = grayScaleToRgbx(
          cy.unsafe[x, y],
        )
  else:
    failInvalid()

proc decodeJpeg*(data: seq[uint8]): Image {.raises: [PixieError].} =
  ## Decodes the JPEG into an Image.

  var state = DecoderState()
  state.buffer = data

  while true:
    if state.readUint8() != 0xFF:
      failInvalid("invalid chunk marker")

    let chunkId = state.readUint8()
    case chunkId:
      of 0xC0:
        # Start Of Frame (Baseline DCT)
        state.decodeSOF0()
      of 0xC1:
        # Start Of Frame (Extended sequential DCT)
        state.decodeSOF1()
      of 0xC2:
        # Start Of Frame (Progressive DCT)
        state.decodeSOF2()
      of 0xC4:
        # Define Huffman Table
        state.decodeDHT()
      of 0xD8:
        # SOI - Start of Image
        continue
      of 0xD9:
        # EOI - End of Image
        break
      of 0xD0 .. 0xD7:
        # Reset markers
        failInvalid("invalid reset marker")
      of 0xDB:
        # Define Quantization Table(s)
        state.decodeDQT()
      of 0xDD:
        # Define Restart Interval
        state.decodeDRI()
      of 0xDA:
        # Start Of Scan
        state.decodeSOS()
        # Entropy-coded data
        state.decodeBlocks()
      of 0XE0:
        # Application-specific
        # state.decodeAPP0(data, at)
        state.skipChunk()
      of 0xE1:
        # Exif
        # state.decodeExif(data, at)
        state.skipChunk()
      of 0xE2..0xEF:
        # Application-specific
        state.skipChunk()
      of 0xFE:
        # Comment
        state.skipChunk()
      else:
        failInvalid("invalid chunk " & chunkId.toHex())

  state.quantizationAndIDCTPass()

  state.buildImage()

proc decodeJpeg*(data: string): Image {.inline, raises: [PixieError].} =
  decodeJpeg(cast[seq[uint8]](data))

proc encodeJpeg*(image: Image): string =
  raise newException(PixieError, "Encoding JPG not supported yet")

when defined(release):
  {.pop.}
