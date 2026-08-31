#pragma once
#if defined(PARANOIA_IOS)

#include <QString>

// Нативное чтение текста из системного буфера обмена (UIPasteboard).
//
// Зачем: Qt-путь (QClipboard -> QIOSMimeData) сопоставляет UTI буфера с MIME
// вручную и при неузнанном типе молча отдаёт пусто, не доходя до чтения данных —
// системный запрос «Разрешить вставку» при этом не показывается. UIPasteboard.string
// отдаёт любой текст, который система умеет привести к строке, и штатно
// проходит через разрешение iOS 16+.
QString paranoiaIosClipboardText();

#endif
