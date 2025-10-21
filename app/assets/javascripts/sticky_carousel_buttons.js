// Listen for messages from parent via iframe-resizer
(function () {
  let originalSearchFormTop = null;
  let isSticky = false;
  let placeholder = null;

  function handleStickyPosition (iframeTop) {
    // Only enable sticky on large screens (Bootstrap lg breakpoint = 992px)
    if (window.innerWidth < 992) {
      return;
    }

    const searchForm = document.getElementById('carousel-buttons-container');
    if (searchForm) {
      // Store the original position of the search form (once)
      if (originalSearchFormTop === null) {
        originalSearchFormTop = searchForm.offsetTop;
      }

      // Calculate how much the iframe has scrolled above the parent viewport
      const iframeScrolledAbove = Math.max(0, -iframeTop);

      // Only stick when we've scrolled past the search form's original position
      if (iframeScrolledAbove > originalSearchFormTop) {
        if (!isSticky) {
          // Create placeholder to maintain space in document flow
          placeholder = document.createElement('div');
          placeholder.style.height = searchForm.offsetHeight + 'px';
          searchForm.parentNode.insertBefore(placeholder, searchForm);

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
          // Remove placeholder
          if (placeholder && placeholder.parentNode) {
            placeholder.parentNode.removeChild(placeholder);
            placeholder = null;
          }

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

  window.iFrameResizer = {
    onMessage: function (message) {
      if (message.type === 'parentScroll') {
        handleStickyPosition(message.iframeTop);
      }
    },
    onReady: function () {
      // Trigger on page load with initial iframe position
      if (window.frameElement) {
        const iframeRect = window.frameElement.getBoundingClientRect();
        handleStickyPosition(iframeRect.top);
      }
    }
  };

  // Also trigger on DOM ready in case iframe is already loaded
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      if (window.frameElement) {
        const iframeRect = window.frameElement.getBoundingClientRect();
        handleStickyPosition(iframeRect.top);
      }
    });
  }
})();