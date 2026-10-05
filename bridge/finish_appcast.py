#!/usr/bin/env python3
"""Keep Sparkle 2.9.6 installation metadata securely serializable."""
import sys
from pathlib import Path
from xml.dom import minidom

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MINIMUM_UPDATE_VERSION = "1.0.7"
MANUAL_TITLE = "Installation manuelle du Companion "


def children(node, name, namespace=None):
    return [child for child in node.childNodes
            if child.nodeType == child.ELEMENT_NODE
            and (child.localName if namespace else child.tagName) == name
            and (namespace is None or child.namespaceURI == namespace)]


def text(node):
    return "".join(child.data for child in node.childNodes
                   if child.nodeType in (child.TEXT_NODE, child.CDATA_SECTION_NODE)).strip()


def element(document, name, value, sparkle=False):
    node = document.createElementNS(SPARKLE, "sparkle:" + name) if sparkle else document.createElement(name)
    node.appendChild(document.createTextNode(value))
    return node


def finish_appcast(data):
    document = minidom.parseString(data)
    channels = document.getElementsByTagName("channel")
    if len(channels) != 1:
        raise ValueError("Expected one appcast channel")
    channel = channels[0]
    installable = []
    for item in children(channel, "item"):
        if not children(item, "enclosure"):
            title = children(item, "title")
            if title and text(title[0]).startswith(MANUAL_TITLE):
                channel.removeChild(item)
            continue
        installable.append(item)
        minimum = children(item, "minimumUpdateVersion", SPARKLE)
        for informational in children(item, "informationalUpdate", SPARKLE):
            below = children(informational, "belowVersion", SPARKLE)
            elements = [node for node in informational.childNodes if node.nodeType == node.ELEMENT_NODE]
            if len(below) != 1 or len(elements) != 1 or text(below[0]) != MINIMUM_UPDATE_VERSION:
                raise ValueError("Refusing to change an unknown informational-update policy")
            if not minimum:
                gate = element(document, "minimumUpdateVersion", MINIMUM_UPDATE_VERSION, sparkle=True)
                item.replaceChild(gate, informational)
                minimum = [gate]
            else:
                item.removeChild(informational)
        if not minimum:
            gate = element(document, "minimumUpdateVersion", MINIMUM_UPDATE_VERSION, sparkle=True)
            versions = children(item, "version", SPARKLE)
            if not versions:
                raise ValueError("Missing appcast version")
            item.insertBefore(gate, versions[0])
            item.insertBefore(document.createTextNode("\n            "), versions[0])
    if not installable:
        raise ValueError("Missing installable update")

    # informationalUpdate is parsed into an NSSet that Sparkle 2.9.6 cannot
    # securely decode inside propertiesDictionary. A separate enclosure-free
    # item preserves the manual-install link for pre-1.0.7 clients without it.
    latest = installable[0]
    version = text(children(latest, "version", SPARKLE)[0])
    fallback = document.createElement("item")
    fallback.appendChild(document.createTextNode("\n            "))
    fallback.appendChild(element(document, "title", MANUAL_TITLE + version))
    for name, namespace in [("pubDate", None), ("link", None),
                            ("version", SPARKLE), ("shortVersionString", SPARKLE),
                            ("minimumSystemVersion", SPARKLE), ("maximumSystemVersion", SPARKLE)]:
        for node in children(latest, name, namespace):
            fallback.appendChild(document.createTextNode("\n            "))
            fallback.appendChild(node.cloneNode(deep=True))
    fallback.appendChild(document.createTextNode("\n            "))
    fallback.appendChild(element(document, "description",
        "Les versions antérieures à 1.0.7 doivent être réinstallées depuis la page de téléchargement. "
        "Leurs préférences et leur source de quotas doivent être conservées."))
    fallback.appendChild(document.createTextNode("\n        "))
    reference = latest.nextSibling
    channel.insertBefore(document.createTextNode("\n        "), reference)
    channel.insertBefore(fallback, reference)
    return document.toxml(encoding="utf-8", standalone=True)


if __name__ == "__main__":
    path = Path(sys.argv[1])
    path.write_bytes(finish_appcast(path.read_bytes()))
