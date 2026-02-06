// LiveView Hooks
let Hooks = {};

// QR Code rendering hook
Hooks.QRCode = {
  mounted() {
    this.renderQR();
  },
  updated() {
    this.renderQR();
  },
  renderQR() {
    const qrData = this.el.dataset.qr;
    if (qrData && typeof QRCode !== 'undefined') {
      this.el.innerHTML = '';
      QRCode.toCanvas(qrData, { width: 256, margin: 2 }, (error, canvas) => {
        if (!error) {
          this.el.appendChild(canvas);
        }
      });
    }
  }
};

// Initialize LiveSocket with hooks
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken }
});
liveSocket.connect();

// Handle flash close
document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
  el.addEventListener("click", () => {
    el.setAttribute("hidden", "");
  });
});
