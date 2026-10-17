/**
 * Buffer.alloc and Buffer.from arrived in Node 4.5, but webOS 3.x ships Node
 * 0.12. These fall back to the deprecated constructor only where the safe
 * APIs are missing.
 */
export function allocBuffer(size: number): Buffer {
  if (typeof Buffer.alloc === 'function') {
    return Buffer.alloc(size);
  }
  const buffer = new Buffer(size);
  buffer.fill(0);
  return buffer;
}

export function copyBuffer(source: Buffer): Buffer {
  const copy = allocBuffer(source.length);
  source.copy(copy);
  return copy;
}
