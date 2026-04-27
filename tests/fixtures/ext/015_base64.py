import base64

data = b'Hello, World!'

# b64encode / b64decode
enc = base64.b64encode(data)
print(enc)                                             # b'SGVsbG8sIFdvcmxkIQ=='
dec = base64.b64decode(enc)
print(dec)                                             # b'Hello, World!'
print(dec == data)                                     # True

# b64encode with padding
print(base64.b64encode(b'a'))                          # b'YQ=='
print(base64.b64encode(b'ab'))                         # b'YWI='
print(base64.b64encode(b'abc'))                        # b'YWJj'

# urlsafe variants (replace + with - and / with _)
url_data = b'\xfb\xff\xfe'
enc_safe = base64.urlsafe_b64encode(url_data)
print(enc_safe)                                        # b'-__-'
dec_safe = base64.urlsafe_b64decode(enc_safe)
print(dec_safe == url_data)                            # True

# b32encode / b32decode
enc32 = base64.b32encode(data)
print(enc32)                                           # b'JBSWY3DPFQQFO33SNRSCC==='
dec32 = base64.b32decode(enc32)
print(dec32 == data)                                   # True

# b16encode / b16decode (hex)
enc16 = base64.b16encode(data)
print(enc16)                                           # b'48656C6C6F2C20576F726C6421'
dec16 = base64.b16decode(enc16)
print(dec16 == data)                                   # True

# decode with bytes and str both work
print(base64.b64decode(b'SGVsbG8='))                   # b'Hello'
print(base64.b64decode('SGVsbG8='))                    # b'Hello'

print('done')
