# slack-eew

緊急地震速報をslackに通知します。
ウェザーニュースの契約が必要です

## 設定

eew.rbの定数を編集してください。

```
UserID: ウェザーニュースのID
Password: ウェザーニュースのパスワード

SlackToken: slackのtoken (legacy token?)
Channel: 通知するchannel
SlackUsername: 通知で表示されるユーザ名
IconURL: 通知のアイコンのURL
```

## 起動

```
bundle exec ruby eew.rb
```

eew.serviceはSystemdのUnitファイルの例です。
