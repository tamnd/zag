import uuid

# uuid5 is deterministic (SHA-1 based)
u5 = uuid.uuid5(uuid.NAMESPACE_DNS, 'python.org')
print(str(u5))
print(u5.version)

# uuid3 is deterministic (MD5 based)
u3 = uuid.uuid3(uuid.NAMESPACE_DNS, 'python.org')
print(str(u3))
print(u3.version)

# UUID from canonical string
u = uuid.UUID('550e8400-e29b-41d4-a716-446655440000')
print(str(u))
print(u.version)

# uuid4: random, test properties only
u4 = uuid.uuid4()
print(u4.version)
print(len(str(u4)))

# NAMESPACE constants
print(str(uuid.NAMESPACE_DNS))
print(str(uuid.NAMESPACE_URL))
