# textwrap module

import textwrap

# wrap
text = 'This is a long paragraph that needs to be wrapped at a reasonable width for readability.'
wrapped = textwrap.wrap(text, width=40)
for line in wrapped:
    print(line)

# fill
filled = textwrap.fill(text, width=40)
print(type(filled).__name__)                        # str
print(len(filled.split('\n')) > 1)                  # True

# shorten
short = textwrap.shorten(text, width=40, placeholder='...')
print(short)                                        # This is a long paragraph that...

# dedent
indented = '''
    Hello
    World
    Python
    '''
dedented = textwrap.dedent(indented)
print(repr(dedented))

# indent
plain = 'Hello\nWorld\nPython'
indented2 = textwrap.indent(plain, '> ')
print(indented2)
# > Hello
# > World
# > Python

# indent with predicate
indented3 = textwrap.indent(plain, '# ', predicate=lambda line: not line.startswith('W'))
print(indented3)
# # Hello
# World
# # Python

# wrap with various options
t2 = 'Hello World'
print(textwrap.wrap(t2, width=5))                  # ['Hello', 'World']

# initial_indent and subsequent_indent
long_text = 'The quick brown fox jumps over the lazy dog.'
result = textwrap.fill(long_text, width=25, initial_indent='  ', subsequent_indent='    ')
for line in result.split('\n'):
    print(repr(line))

print('done')
