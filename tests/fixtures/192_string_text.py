import string
import textwrap

# string constants
print(len(string.ascii_letters) == 52)                 # True
print(len(string.digits) == 10)                        # True
print(len(string.punctuation) > 0)                     # True
print(string.ascii_lowercase[:3])                      # abc
print(string.ascii_uppercase[:3])                      # ABC
print(string.digits[:5])                               # 01234

# string.Template
t = string.Template('Hello, $name! You are $age.')
result = t.substitute(name='Alice', age=30)
print(result)                                          # Hello, Alice! You are 30.

t2 = string.Template('$who likes $what')
print(t2.safe_substitute(who='Bob'))                   # Bob likes $what

# textwrap.wrap
text = 'This is a long sentence that should be wrapped at a certain width.'
wrapped = textwrap.wrap(text, width=30)
print(len(wrapped) > 1)                                # True
print(all(len(w) <= 30 for w in wrapped))              # True

# textwrap.fill
filled = textwrap.fill(text, width=40)
print(isinstance(filled, str))                         # True
print('\n' in filled)                                  # True

# textwrap.dedent
indented = '    line1\n    line2\n    line3'
dedented = textwrap.dedent(indented)
print(dedented.startswith('line1'))                    # True

# textwrap.indent
result = textwrap.indent('line1\nline2', '> ')
print(result)                                          # > line1\n> line2

print('done')
