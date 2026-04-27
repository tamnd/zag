from urllib.parse import (
    urlparse, urlunparse, urlencode, urljoin,
    quote, unquote, parse_qs, parse_qsl, urlsplit
)

# urlparse
r = urlparse('https://user:pass@example.com:8080/path?a=1&b=2#frag')
print(r.scheme)                                        # https
print(r.netloc)                                        # user:pass@example.com:8080
print(r.path)                                          # /path
print(r.query)                                         # a=1&b=2
print(r.fragment)                                      # frag
print(r.username)                                      # user
print(r.password)                                      # pass
print(r.hostname)                                      # example.com
print(r.port)                                          # 8080

# urlunparse
parts = ('https', 'example.com', '/path', '', 'q=1', '')
url = urlunparse(parts)
print('https' in url)                                  # True
print('example.com' in url)                            # True

# urljoin
print(urljoin('https://example.com/base/', 'page'))    # https://example.com/base/page
print(urljoin('https://example.com/a/b', '/c'))        # https://example.com/c

# quote / unquote
q = quote('hello world')
print(q)                                               # hello%20world
print(unquote(q))                                      # hello world
print(quote('a/b', safe='/'))                          # a/b

# urlencode
params = [('a', 1), ('b', 'hello world')]
encoded = urlencode(params)
print(encoded)                                         # a=1&b=hello+world

# parse_qs
qs = parse_qs('a=1&b=2&b=3')
print(qs['a'])                                         # ['1']
print(sorted(qs['b']))                                 # ['2', '3']

# parse_qsl
qsl = parse_qsl('x=1&y=2')
print(qsl)                                             # [('x', '1'), ('y', '2')]

# urlsplit
sp = urlsplit('https://example.com/path?q=1')
print(sp.scheme)                                       # https
print(sp.path)                                         # /path

print('done')
