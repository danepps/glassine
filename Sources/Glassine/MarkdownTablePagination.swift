import Foundation

/// WebKit's print path neither repeats THEAD nor reliably keeps TR together.
/// Prepare separate, unbreakable table sections at the actual print width.
/// This runs in the client content world, with document scripts still disabled.
enum MarkdownTablePagination {
    static let script = #"""
    await document.fonts.ready;
    const pageHeight = printableHeight;
    const pageRoom = pageHeight - 8; // Border and print rounding allowance.
    for (const table of Array.from(document.querySelectorAll('table'))) {
        if (table.parentElement.closest('table')) continue;
        const header = table.tHead;
        const rows = Array.from(table.tBodies).flatMap(body => Array.from(body.rows));
        if (!header || !rows.length || table.tBodies.length !== 1) continue;
        const cells = Array.from(header.rows[0]?.cells || []);
        // Markdown tables have one simple header row. Leave raw HTML tables
        // with spanning cells to their own layout instead of breaking spans.
        if (header.rows.length !== 1 || !cells.length ||
            Array.from(table.rows).some(row => row.cells.length !== cells.length ||
                Array.from(row.cells).some(cell => cell.colSpan !== 1 || cell.rowSpan !== 1))) continue;

        const rect = table.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) continue;
        const widths = cells.map(cell => cell.getBoundingClientRect().width);
        const headerHeight = header.getBoundingClientRect().height;
        const captionHeight = table.caption?.getBoundingClientRect().height || 0;
        const footerHeight = table.tFoot?.getBoundingClientRect().height || 0;
        const rowHeights = rows.map(row => row.getBoundingClientRect().height);
        const style = getComputedStyle(table);
        const firstRoom = pageRoom - ((rect.top + window.scrollY) % pageHeight);
        const sections = [];
        let start = 0;
        let first = true;
        // Native pagination before this table can move its starting point.
        // Keep a short table whole instead of making a tiny first section
        // that might itself get pushed onto a fresh, mostly empty page.
        if (rect.height <= pageRoom) {
            sections.push({ start: 0, end: rows.length, newPage: false, oversized: false });
            start = rows.length;
        }
        while (start < rows.length) {
            let room = first ? firstRoom : pageRoom;
            let height = headerHeight + (first ? captionHeight : 0);
            let newPage = !first;
            if (height + rowHeights[start] > room) {
                room = pageRoom;
            }
            let end = start;
            while (end < rows.length && height + rowHeights[end] +
                (end === rows.length - 1 ? footerHeight : 0) <= room) {
                height += rowHeights[end++];
            }
            // An individual row taller than a page must remain breakable;
            // never clip or omit its text to make it fit.
            const oversized = end === start;
            if (oversized) end++;
            sections.push({ start, end, newPage, oversized });
            start = end;
            first = false;
        }

        const fragment = document.createDocumentFragment();
        sections.forEach((section, index) => {
            const wrapper = document.createElement('div');
            wrapper.className = 'glassine-table-section';
            wrapper.style.breakInside = section.oversized ? 'auto' : 'avoid';
            wrapper.style.pageBreakInside = section.oversized ? 'auto' : 'avoid';
            if (section.newPage) {
                wrapper.style.breakBefore = 'page';
                wrapper.style.pageBreakBefore = 'always';
            }
            wrapper.style.marginTop = index === 0 ? style.marginTop : '0';
            wrapper.style.marginBottom = index === sections.length - 1 ? style.marginBottom : '0';
            const copy = table.cloneNode(false);
            // Fix the original column widths so a continuation with different
            // cell contents cannot resize its columns or wrap rows differently.
            copy.style.width = rect.width + 'px';
            copy.style.tableLayout = 'fixed';
            copy.style.margin = '0';
            if (index === 0 && table.caption) copy.append(table.caption.cloneNode(true));
            const columns = document.createElement('colgroup');
            widths.forEach(width => {
                const col = document.createElement('col');
                col.style.width = width + 'px';
                columns.append(col);
            });
            copy.append(columns, header.cloneNode(true));
            const body = table.tBodies[0].cloneNode(false);
            if (index > 0) body.removeAttribute('id');
            for (let row = section.start; row < section.end; row++) {
                body.append(rows[row].cloneNode(true));
            }
            copy.append(body);
            if (index === sections.length - 1 && table.tFoot) copy.append(table.tFoot.cloneNode(true));
            // Only the first section owns the table/header fragment targets.
            if (index > 0) {
                copy.removeAttribute('id');
                copy.tHead.removeAttribute('id');
                copy.querySelectorAll('thead [id]').forEach(node => node.removeAttribute('id'));
            }
            wrapper.append(copy);
            fragment.append(wrapper);
        });
        table.replaceWith(fragment);
    }
    return true;
    """#
}
