// Ask Lisp for a few facts and list them.
proteus.invoke('lisp-facts').then(facts => {
  const list = document.getElementById('facts');
  for (const [name, value] of Object.entries(facts)) {
    const dt = document.createElement('dt');
    dt.textContent = name;
    const dd = document.createElement('dd');
    dd.textContent = Array.isArray(value) ? value.join(', ') : value;
    list.append(dt, dd);
  }
  document.title = 'Facts: ' + facts.implementation;
});
