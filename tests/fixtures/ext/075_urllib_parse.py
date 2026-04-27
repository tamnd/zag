# urllib.parse module

from urllib.parse import (urlparse, urlunparse, urlencode,
                          quote, unquote, quote_plus, unquote_plus,
                          parse_qs, parse_qsl, urlsplit,
                          urljoin)

# urlparse
result = urlparse('https://www.example.com:8080/path/page?query=value&a=1#section')
print(result.scheme)                               # https
print(result.netloc)                               # www.example.com:8080
print(result.path)                                 # /path/page
print(result.query)                                # query=value&a=1
print(result.fragment)                             # section
print(result.hostname)                             # www.example.com
print(result.port)                                 # 8080

# urlunparse
parts = ('https', 'example.com', '/path', '', 'q=1', 'frag')
print(urlunparse(parts))                          # https://example.com/path?q=1#frag

# urlencode
params = {'name': 'Alice', 'age': '30'}
encoded = urlencode(params)
print('name=Alice' in encoded)                     # True

# quote / unquote
print(quote('hello world'))                        # hello%20world
print(quote('/path/to/file'))                      # /path/to/file
print(quote('/path/to/file', safe=''))             # %2Fpath%2Fto%2Ffile
print(unquote('hello%20world'))                    # hello world

# quote_plus / unquote_plus
print(quote_plus('hello world'))                   # hello+world
print(unquote_plus('hello+world'))                 # hello world

# parse_qs
qs = parse_qs('a=1&b=2&a=3')
print(sorted(qs.items()))                          # [('a', ['1', '3']), ('b', ['2'])]

# parse_qsl (preserves order)
qsl = parse_qsl('a=1&b=2&a=3')
print(qsl)                                         # [('a', '1'), ('b', '2'), ('a', '3')]

# urljoin
print(urljoin('https://example.com/foo/', 'bar'))  # https://example.com/foo/bar
print(urljoin('https://example.com/foo/', '/bar')) # https://example.com/bar
print(urljoin('https://example.com/', 'https://other.com/'))  # https://other.com/

# urlsplit
r2 = urlsplit('https://user:pass@host:80/path?q=1')
print(r2.username)                                 # user
print(r2.password)                                 # pass

print('done')
