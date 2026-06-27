import QtQuick

QtObject {
  id: root

  property var chats: []
  property var communities: []
  property int nextId: 1

  function conversationsForMode(mode) {
    return mode === "communities" ? communities : chats;
  }

  function conversationById(id) {
    const all = chats.concat(communities);
    for (const conversation of all) {
      if (conversation.id === id) return conversation;
    }
    return null;
  }

  function messagesFor(id) {
    return conversationById(id)?.messages || [];
  }

  function addConversation(data) {
    const section = data.section === "communities" ? "communities" : "chats";
    const id = data.id || ("conversation-" + nextId++);
    const conversation = {
      id,
      section,
      title: data.title || "Untitled",
      subtitle: data.subtitle || "",
      chatTitle: data.chatTitle || data.title || "Untitled",
      avatarText: data.avatarText || initials(data.title || "?"),
      avatarColor: data.avatarColor || "#f3f3f3",
      avatarTextColor: data.avatarTextColor || "#1f231f",
      icon: data.icon || "",
      online: data.online === true,
      snoozed: data.snoozed === true,
      trackPreview: data.trackPreview !== false,
      messages: [],
    };

    if (section === "communities") communities = communities.concat([conversation]);
    else chats = chats.concat([conversation]);

    return id;
  }

  function addMessage(conversationId, message) {
    replaceConversation(conversationId, conversation => {
      const next = cloneConversation(conversation);
      const text = message.text || "";
      next.messages = next.messages.concat([{
        author: message.author || next.chatTitle,
        time: message.time || "",
        text,
        avatarText: message.avatarText || next.avatarText,
        avatarColor: message.avatarColor || next.avatarColor,
        avatarTextColor: message.avatarTextColor || next.avatarTextColor,
        icon: message.icon || "",
        online: message.online === true,
        mine: message.mine === true,
      }]);
      if (next.trackPreview && text !== "") next.subtitle = text;
      return next;
    });
  }

  function addDemoConversation(section) {
    const n = conversationsForMode(section).length + 1;
    const id = addConversation({
      section,
      title: section === "communities" ? ("New Community " + n) : ("New Chat " + n),
      subtitle: section === "communities" ? "1 member" : "Created just now",
      chatTitle: section === "communities" ? ("New Community " + n) : ("New Chat " + n),
      avatarText: section === "communities" ? "NC" : "N",
      avatarColor: section === "communities" ? "#ffefcb" : "#dff5e6",
      avatarTextColor: "#1f231f",
      trackPreview: section !== "communities",
    });
    addMessage(id, {
      author: section === "communities" ? "host" : "You",
      time: "now",
      text: "This conversation was added with addConversation() and addMessage().",
      avatarText: section === "communities" ? "H" : "Y",
      avatarColor: section === "communities" ? "#ffdfb4" : "#dff5e6",
      avatarTextColor: "#1f231f",
      mine: section !== "communities",
    });
    return id;
  }

  function seedDemoData() {
    if (chats.length > 0 || communities.length > 0) return;

    const clanPublic = addConversation({
      id: "clan-public",
      section: "chats",
      title: "Clan Public",
      subtitle: "5 members",
      chatTitle: "Clan Public",
      avatarText: "CP",
      avatarColor: "#ffefee",
      avatarTextColor: "#6b6b6b",
      icon: "home",
      trackPreview: false,
    });
    addRetroMessages(clanPublic);

    const mattSaoriAndy = addConversation({
      id: "matt-saori-andy",
      section: "chats",
      title: "Matt, Saori & Andy",
      subtitle: "Ok, sounds good",
      chatTitle: "Matt, Saori & Andy",
      avatarText: "MS",
      avatarColor: "#b8c9c3",
      avatarTextColor: "#1f231f",
      trackPreview: false,
    });
    addRetroMessages(mattSaoriAndy);

    const mattPhilAnn = addConversation({
      id: "matt-phil-ann",
      section: "chats",
      title: "Matt, Phil & Ann",
      subtitle: "Thanks, see you then",
      chatTitle: "Matt, Phil & Ann",
      avatarText: "MP",
      avatarColor: "#d66548",
      avatarTextColor: "#fff8f4",
      trackPreview: false,
    });
    addRetroMessages(mattPhilAnn);

    seedDirectChat("matt", "Matt", "You", "M", "#57b886", "#1f231f", false, false);
    seedDirectChat("saori", "Saori", "Where are you?", "S", "#6c8f49", "#ffffff", true, false);
    seedDirectChat("andy", "Andy", "Should be fine with that", "A", "#f3a2ef", "#1f231f", true, false);
    seedDirectChat("ann", "Ann", "Thanks, see you on Thursday", "A", "#ff7c6f", "#1f231f", false, true);
    seedDirectChat("phil", "Phil", "Yeah that was definitely a dad joke", "P", "#a7b1d4", "#1f231f", false, true);

    seedCommunity("ancient-gamers", "Ancient Gamers", "27 members", "AG", "#ffefee", "#171717", "AG: Town Hall");
    seedCommunity("bicycle-company", "The Bicycle Company", "36 members", "BC", "#f69371", "#171717", "The Bicycle Company");
    seedCommunity("retrojapan", "RetroJapan", "86 members", "RJ", "#d66548", "#ffffff", "RetroJapan");
    seedCommunity("vintage-computers", "Vintage Computers", "52 members", "VC", "#ffefcb", "#171717", "Vintage Computers");
    seedCommunity("community-clan-public", "Clan Public", "5 members", "CP", "#ffefee", "#6b6b6b", "Clan Public", "home");
  }

  function seedDirectChat(id, title, subtitle, avatarText, avatarColor, avatarTextColor, online, snoozed) {
    const conversationId = addConversation({
      id,
      section: "chats",
      title,
      subtitle,
      chatTitle: title,
      avatarText,
      avatarColor,
      avatarTextColor,
      online,
      snoozed,
      trackPreview: false,
    });
    addRetroMessages(conversationId);
  }

  function seedCommunity(id, title, subtitle, avatarText, avatarColor, avatarTextColor, chatTitle, icon) {
    const conversationId = addConversation({
      id,
      section: "communities",
      title,
      subtitle,
      chatTitle,
      avatarText,
      avatarColor,
      avatarTextColor,
      icon: icon || "",
      trackPreview: false,
    });
    addRetroMessages(conversationId);
  }

  function addRetroMessages(conversationId) {
    addMessage(conversationId, {
      author: "Adrock",
      time: "3:19pm",
      text: "So what do we think about the C64 Ultimate?",
      avatarText: "A",
      avatarColor: "#ffdfb4",
      avatarTextColor: "#1f231f",
    });
    addMessage(conversationId, {
      author: "Bd_wolf",
      time: "3:20pm",
      text: "Already pre-ordered! Beige, obviously",
      avatarText: "BW",
      avatarColor: "#ffd957",
      avatarTextColor: "#1f231f",
    });
    addMessage(conversationId, {
      author: "Adrock",
      time: "3:21pm",
      text: "Much as i love a good beige, i think i'm going RGB on this one",
      avatarText: "A",
      avatarColor: "#ffdfb4",
      avatarTextColor: "#1f231f",
    });
    addMessage(conversationId, {
      author: "Bd_wolf",
      time: "3:22pm",
      text: "I figured you as a gold badges kind of guy",
      avatarText: "BW",
      avatarColor: "#ffd957",
      avatarTextColor: "#1f231f",
    });
    addMessage(conversationId, {
      author: "cosmic_psychonaut",
      time: "3:25pm",
      text: "Yeah that Founders Edition is bananas",
      avatarText: "CP",
      avatarColor: "#9cab48",
      avatarTextColor: "#1f231f",
    });
  }

  function replaceConversation(id, update) {
    let changed = false;
    const nextChats = [];
    for (const conversation of chats) {
      if (conversation.id === id) {
        nextChats.push(update(conversation));
        changed = true;
      } else {
        nextChats.push(conversation);
      }
    }
    if (changed) {
      chats = nextChats;
      return;
    }

    const nextCommunities = [];
    for (const conversation of communities) {
      if (conversation.id === id) {
        nextCommunities.push(update(conversation));
        changed = true;
      } else {
        nextCommunities.push(conversation);
      }
    }
    if (changed) communities = nextCommunities;
  }

  function cloneConversation(conversation) {
    return {
      id: conversation.id,
      section: conversation.section,
      title: conversation.title,
      subtitle: conversation.subtitle,
      chatTitle: conversation.chatTitle,
      avatarText: conversation.avatarText,
      avatarColor: conversation.avatarColor,
      avatarTextColor: conversation.avatarTextColor,
      icon: conversation.icon,
      online: conversation.online,
      snoozed: conversation.snoozed,
      trackPreview: conversation.trackPreview,
      messages: conversation.messages || [],
    };
  }

  function initials(name) {
    const parts = String(name || "?").split(/[ ,&]+/).filter(p => p.length > 0);
    if (parts.length === 0) return "?";
    if (parts.length === 1) return String(parts[0]).slice(0, 2).toUpperCase();
    return String(parts[0]).slice(0, 1).toUpperCase()
      + String(parts[1]).slice(0, 1).toUpperCase();
  }

  Component.onCompleted: seedDemoData()
}
