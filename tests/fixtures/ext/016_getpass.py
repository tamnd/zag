import getpass

# getuser() returns the current username as a string
user = getpass.getuser()
print(isinstance(user, str))                           # True
print(len(user) > 0)                                   # True

# getpass module has getpass function (interactive -- do not call it)
print(callable(getpass.getpass))                       # True

# module-level attributes
print(hasattr(getpass, 'getuser'))                     # True
print(hasattr(getpass, 'getpass'))                     # True

print('done')
