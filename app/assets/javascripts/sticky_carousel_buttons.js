// Listen for messages from parent via iframe-resizer
(function () {
  let originalSearchFormTop = null;
  let isSticky = false;
  let placeholder = null;
  let scrollTimeout = null;
  let isScrolling = false;

  window.iFrameResizer = {
    onReady: function () {
      // Send message to parent when iframe-resizer is ready
      console.log('iframe-resizer ready, sending message to parent');
      window.parentIFrame.sendMessage('iframeLoaded');
    },
    onMessage: function (message) {
      if (message.type === 'parentScroll') {
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
          const iframeScrolledAbove = Math.max(0, -message.iframeTop);

          // Only stick when we've scrolled past the search form's original position
          if (iframeScrolledAbove > originalSearchFormTop) {
            // Hide immediately when scrolling starts (only when sticky)
            if (!isScrolling) {
              isScrolling = true;
              searchForm.style.opacity = '0';
              searchForm.style.transition = 'opacity 0s ease-out';
            }

            // Clear previous timeout
            if (scrollTimeout) {
              clearTimeout(scrollTimeout);
            }

            // Set timeout to show again after scrolling stops
            scrollTimeout = setTimeout(function () {
              isScrolling = false;
              searchForm.style.opacity = '1';
              searchForm.style.transition = 'opacity 0.25s ease-in';
            }, 150);
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
    }
  };
})();