// Short confirmations at the bottom of the window.

let timer = 0;

export function toast(message, { error = false } = {}) {
    const el = document.getElementById('toast');
    el.textContent = message;
    el.classList.toggle('error', error);
    el.classList.add('show');
    clearTimeout(timer);
    timer = setTimeout(() => el.classList.remove('show'), error ? 4000 : 2200);
}
