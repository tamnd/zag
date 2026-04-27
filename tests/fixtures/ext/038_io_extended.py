import io

# BytesIO
buf = io.BytesIO()
buf.write(b'hello')
buf.write(b' world')
print(buf.getvalue())                                 # b'hello world'

buf.seek(0)
print(buf.read(5))                                    # b'hello'
print(buf.tell())                                     # 5

# BytesIO with initial value
buf2 = io.BytesIO(b'initial')
print(buf2.read())                                    # b'initial'

# StringIO
sbuf = io.StringIO()
sbuf.write('line1\n')
sbuf.write('line2\n')
sbuf.seek(0)
lines = sbuf.readlines()
print(len(lines))                                     # 2
print(lines[0].strip())                               # line1
print(lines[1].strip())                               # line2

# StringIO getvalue after write
sbuf2 = io.StringIO()
sbuf2.write('hello')
sbuf2.write(' world')
print(sbuf2.getvalue())                               # hello world

# tell and seek
sbuf3 = io.StringIO('abcdef')
print(sbuf3.read(3))                                  # abc
print(sbuf3.tell())                                   # 3
sbuf3.seek(0)
print(sbuf3.read())                                   # abcdef

# truncate
sbuf4 = io.StringIO('hello world')
sbuf4.seek(5)
sbuf4.truncate()
sbuf4.seek(0)
print(sbuf4.read())                                   # hello

print('done')
