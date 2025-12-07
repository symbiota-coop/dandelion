$.currencySymbol = function (currency) {
  try {
    const parts = new Intl.NumberFormat('en', { style: 'currency', currency: currency })
      .formatToParts();
    const symbol = parts.find(part => part.type === 'currency');
    const symbolValue = symbol ? symbol.value : currency;

    // If symbol is compound (>1 char) and ends with $, return original currency code
    return (symbolValue.length > 1 && symbolValue.endsWith('$')) ? currency : symbolValue;
  } catch (e) {
    return currency;
  }
}

