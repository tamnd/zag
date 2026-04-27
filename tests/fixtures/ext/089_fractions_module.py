# fractions module

from fractions import Fraction

# Basic creation
f1 = Fraction(1, 3)
f2 = Fraction(2, 3)
print(f1)                                         # 1/3
print(f2)                                         # 2/3

# From string
f3 = Fraction('3/4')
print(f3)                                         # 3/4

# From float (approximation)
f4 = Fraction(0.25)
print(f4)                                         # 1/4

# From integer
f5 = Fraction(5)
print(f5)                                         # 5

# Arithmetic
print(f1 + f2)                                    # 1
print(f1 - f2)                                    # -1/3
print(f1 * f2)                                    # 2/9
print(f2 / f1)                                    # 2

# Comparison
print(f1 < f2)                                    # True
print(f1 == Fraction(1, 3))                       # True

# numerator and denominator
print(f3.numerator)                               # 3
print(f3.denominator)                             # 4

# Mixed arithmetic with int
print(f1 + 1)                                     # 4/3
print(2 * f2)                                     # 4/3

# limit_denominator
pi_approx = Fraction(22, 7)
print(pi_approx)                                  # 22/7
print(float(pi_approx) > 3.14)                    # True

# Fraction from decimal string
f6 = Fraction('0.5')
print(f6)                                         # 1/2

# Reduce to lowest terms
f7 = Fraction(6, 4)
print(f7)                                         # 3/2

# abs
print(abs(Fraction(-3, 4)))                       # 3/4

# Power
print(Fraction(2, 3) ** 2)                        # 4/9
print(Fraction(4, 9) ** Fraction(1, 2))           # 2/3

print('done')
