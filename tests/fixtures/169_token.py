import token

# Spot-check that the named constants are integers
print(isinstance(token.NAME, int))                     # True
print(isinstance(token.NUMBER, int))                   # True
print(isinstance(token.STRING, int))                   # True
print(isinstance(token.NEWLINE, int))                  # True
print(isinstance(token.INDENT, int))                   # True
print(isinstance(token.DEDENT, int))                   # True
print(isinstance(token.OP, int))                       # True
print(isinstance(token.ENDMARKER, int))                # True

# tok_name maps int -> string
print(token.tok_name[token.NAME])                      # NAME
print(token.tok_name[token.NUMBER])                    # NUMBER
print(token.tok_name[token.STRING])                    # STRING
print(token.tok_name[token.NEWLINE])                   # NEWLINE
print(token.tok_name[token.INDENT])                    # INDENT
print(token.tok_name[token.DEDENT])                    # DEDENT

# ISTERMINAL / ISNONTERMINAL / ISEOF
print(token.ISEOF(token.ENDMARKER))                    # True
print(token.ISEOF(token.NAME))                         # False

print('done')
