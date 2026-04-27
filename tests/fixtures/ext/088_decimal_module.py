# decimal module

from decimal import Decimal, getcontext, ROUND_HALF_UP, ROUND_DOWN, ROUND_UP

# Basic creation
d1 = Decimal('3.14')
d2 = Decimal('2.71')
print(d1)                                         # 3.14
print(d2)                                         # 2.71

# Arithmetic
print(d1 + d2)                                    # 5.85
print(d1 - d2)                                    # 0.43
print(d1 * d2)                                    # 8.5094

# Comparison
print(d1 > d2)                                    # True
print(d1 == Decimal('3.14'))                      # True

# From int
d3 = Decimal(42)
print(d3)                                         # 42
d4 = Decimal('0.1') + Decimal('0.2')
print(d4)                                         # 0.3

# Context precision
ctx = getcontext()
ctx.prec = 10
print(Decimal('1') / Decimal('3'))                # 0.3333333333

# Rounding
d5 = Decimal('2.5')
print(d5.quantize(Decimal('1'), rounding=ROUND_HALF_UP))  # 3
print(d5.quantize(Decimal('1'), rounding=ROUND_DOWN))     # 2
print(d5.quantize(Decimal('1'), rounding=ROUND_UP))       # 3

# sqrt
d6 = Decimal('2')
print(d6.sqrt().quantize(Decimal('0.00001')))     # 1.41421

# abs
print(abs(Decimal('-3.14')))                      # 3.14

# is_nan, is_infinite, is_finite
print(Decimal('NaN').is_nan())                    # True
print(Decimal('Inf').is_infinite())               # True
print(d1.is_finite())                             # True

# to_integral_value
d7 = Decimal('3.7')
print(d7.to_integral_value())                     # 4
print(Decimal('-3.7').to_integral_value())        # -4

# as_tuple
t = Decimal('3.14').as_tuple()
print(t.sign)                                     # 0
print(t.exponent)                                 # -2

print('done')
