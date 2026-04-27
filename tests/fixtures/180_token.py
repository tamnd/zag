import token

# basic token constants
print(token.ENDMARKER)
print(token.NAME)
print(token.NUMBER)
print(token.STRING)
print(token.NEWLINE)
print(token.INDENT)
print(token.DEDENT)

# punctuation
print(token.LPAR)
print(token.RPAR)
print(token.COLON)
print(token.COMMA)
print(token.DOT)

# tok_name mapping
print(token.tok_name[1])
print(token.tok_name[2])
print(token.tok_name[3])

# ISEOF predicate
print(token.ISEOF(0))
print(token.ISEOF(1))
