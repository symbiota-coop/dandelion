// Listen for messages from parent via iframe-resizer
(function () {
  let originalSearchFormTop = null;
  let isSticky = false;

  window.iFrameResizer = {
    onMessage: function (message) {
      if (message.type === 'parentScroll') {
        // Only enable sticky on large screens (Bootstrap lg breakpoint = 992px)
        if (window.innerWidth < 992) {
          return;
        }

        const searchForm = document.getElementById('events-search-form-container');
        if (searchForm) {
          // Store the original position of the search form (once)
          if (originalSearchFormTop === null) {
            originalSearchFormTop = searchForm.offsetTop;
          }

          // Calculate how much the iframe has scrolled above the parent viewport
          const iframeScrolledAbove = Math.max(0, -message.iframeTop);

          // Only stick when we've scrolled past the search form's original position
          if (iframeScrolledAbove > originalSearchFormTop) {
            if (!isSticky) {
              // First time sticking - add will-change for performance
              searchForm.style.willChange = 'transform';
              isSticky = true;
            }
            searchForm.style.position = 'absolute';
            searchForm.style.transform = `translateY(${iframeScrolledAbove}px)`;
            searchForm.style.top = '0';
            searchForm.style.left = '0';
            searchForm.style.right = '0';
            searchForm.style.zIndex = '100';
          } else {
            if (isSticky) {
              // Remove will-change when not sticky
              searchForm.style.willChange = '';
              isSticky = false;
            }
            // Revert to normal positioning
            searchForm.style.position = '';
            searchForm.style.transform = '';
            searchForm.style.top = '';
            searchForm.style.left = '';
            searchForm.style.right = '';
            searchForm.style.zIndex = '';
          }
        }
      }
    }
  };
})();